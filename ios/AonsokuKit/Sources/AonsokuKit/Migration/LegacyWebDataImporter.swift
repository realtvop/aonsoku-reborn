import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// What `LegacyWebDataImporter` moved into native storage.
public struct LegacyImportReport: Equatable, Sendable {
    public var cacheEntries = 0
    public var lyrics = 0
    public var customLyrics = 0
    /// True when the WebView data could not be read; the import is retried
    /// on the next launch.
    public var failed = false

    public init(
        cacheEntries: Int = 0,
        lyrics: Int = 0,
        customLyrics: Int = 0,
        failed: Bool = false
    ) {
        self.cacheEntries = cacheEntries
        self.lyrics = lyrics
        self.customLyrics = customLyrics
        self.failed = failed
    }
}

/// Reads data the Capacitor app kept in WebView IndexedDB and moves it into
/// native storage, once. A hidden `WKWebView` on the default data store
/// loads a blank page from the old `capacitor://localhost` origin so it can
/// open the same databases:
///
/// - Dexie `aonsoku-library` tables `cacheMeta` and `lyrics`;
/// - idb-keyval `aonsoku-cache` (`cache-index`, `cache-index-v1`) and
///   `aonsoku-offline` (`offline-library`);
/// - `aonsoku-custom-lyrics` (`custom-lyrics:<songKey>` and
///   `custom-lyrics-romaji:<songKey>`).
///
/// Cache rows go to the native `cacheMeta` index, lyrics to the library
/// database, and custom lyrics to the lyrics selections.
@MainActor
public final class LegacyWebDataImporter {
    public static let doneKey = "legacyWebData.imported.v1"

    public let library: LibraryService
    public let preferences: PreferencesService

    private let reader: @MainActor () async throws -> String
    private let now: () -> Date

    public init(library: LibraryService, preferences: PreferencesService) {
        self.library = library
        self.preferences = preferences
        reader = { try await Self.readWebData() }
        now = Date.init
    }

    init(
        library: LibraryService,
        preferences: PreferencesService,
        reader: @escaping @MainActor () async throws -> String,
        now: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.preferences = preferences
        self.reader = reader
        self.now = now
    }

    /// True until an import succeeds.
    public var isNeeded: Bool { preferences.getString(Self.doneKey) == nil }

    public func run() async -> LegacyImportReport {
        guard isNeeded else { return LegacyImportReport() }
        do {
            let json = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { @MainActor [reader] in try await reader() }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw LegacyImportError.timedOut
                }
                guard let value = try await group.next() else {
                    throw LegacyImportError.unavailable
                }
                group.cancelAll()
                return value
            }
            let mapped = try Self.map(
                json: json,
                nativeFileExists: { [library] type, id in
                    switch type {
                    case .audio: Self.nativeAudioExists(songId: id)
                    case .cover: library.coverSize(id: id) != nil
                    case .album, .playlist: true
                    }
                },
                now: now()
            )
            let currentRows = Dictionary(uniqueKeysWithValues:
                ((try? library.cacheMetadata()) ?? []).map { ($0.key, $0) }
            )
            let cacheRows = mapped.cacheRows.filter { row in
                guard let current = currentRows[row.key] else { return true }
                return row.cachedAt >= current.cachedAt
            }
            try library.upsertCacheMetadata(cacheRows)
            for lyric in mapped.lyrics {
                try library.storeImportedLyrics(
                    songId: lyric.songId,
                    content: lyric.content,
                    synced: lyric.synced,
                    cachedAt: lyric.cachedAt,
                    lastAccessedAt: lyric.lastAccessedAt
                )
            }
            let customCount = mergeCustomLyrics(mapped.customLyrics)
            preferences.setString("1", for: Self.doneKey)
            return LegacyImportReport(
                cacheEntries: cacheRows.count,
                lyrics: mapped.lyrics.count,
                customLyrics: customCount
            )
        } catch {
            NativeLogger.shared.error(
                "legacy WebView import failed: \(error)",
                source: "LegacyWebDataImporter"
            )
            return LegacyImportReport(failed: true)
        }
    }

    // MARK: Mapping

    static func map(
        json: String,
        nativeFileExists: (CachedItemType, String) -> Bool,
        now: Date = Date()
    ) throws -> LegacyMappedData {
        guard let data = json.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LegacyImportError.invalidPayload }

        var rawRows = dictionaries(root["cacheMeta"])
        for entry in dictionaries(root["cacheStore"]) {
            guard let key = entry["key"] as? String,
                key == "cache-index" || key == "cache-index-v1"
            else { continue }
            rawRows.append(contentsOf: cacheRows(from: entry["value"]))
        }

        var cacheRowsByKey: [String: CacheMetaRecord] = [:]
        for value in rawRows {
            guard let id = string(value["id"]),
                let typeValue = string(value["type"]),
                let type = CachedItemType(rawValue: typeValue)
            else { continue }
            let key = string(value["key"]) ?? "\(type.rawValue):\(id)"
            guard nativeFileExists(type, id) else { continue }
            let source = CacheSource(stored: string(value["source"]) ?? "explicit")
            let triggers = (value["triggers"] as? [Any])?.compactMap(string)
            let timestamp = milliseconds(value["cachedAt"])
                ?? Int(now.timeIntervalSince1970 * 1_000)
            let row = CacheMetaRecord(
                key: key,
                id: id,
                type: type.rawValue,
                source: source.rawValue,
                triggersJson: jsonString(triggers),
                coverSize: string(value["coverSize"]),
                sizeBytes: integer(value["sizeBytes"]) ?? 0,
                cachedAt: timestamp,
                lastAccessedAt: milliseconds(value["lastAccessedAt"]) ?? timestamp,
                removedFromServer: value["removedFromServer"] as? Bool
            )
            if let existing = cacheRowsByKey[key], existing.cachedAt > row.cachedAt {
                continue
            }
            cacheRowsByKey[key] = row
        }

        let lyrics = dictionaries(root["lyrics"]).compactMap { value -> LegacyLyric? in
            guard let songId = string(value["songId"]),
                let content = string(value["content"]),
                !content.isEmpty
            else { return nil }
            return LegacyLyric(
                songId: songId,
                content: content,
                synced: value["synced"] as? Bool ?? false,
                cachedAt: milliseconds(value["cachedAt"])
                    ?? Int(now.timeIntervalSince1970 * 1_000),
                lastAccessedAt: milliseconds(value["lastAccessedAt"])
                    ?? milliseconds(value["cachedAt"])
                    ?? Int(now.timeIntervalSince1970 * 1_000)
            )
        }

        var custom: [String: LegacyCustomLyrics] = [:]
        for entry in dictionaries(root["customLyrics"]) {
            guard let key = string(entry["key"]), let body = string(entry["value"]) else {
                continue
            }
            if key.hasPrefix("custom-lyrics-romaji:") {
                let songKey = String(key.dropFirst("custom-lyrics-romaji:".count))
                custom[songKey, default: LegacyCustomLyrics()].romaji = body
            } else if key.hasPrefix("custom-lyrics:") {
                let songKey = String(key.dropFirst("custom-lyrics:".count))
                custom[songKey, default: LegacyCustomLyrics()].lyrics = body
            }
        }

        return LegacyMappedData(
            cacheRows: cacheRowsByKey.values.sorted { $0.key < $1.key },
            lyrics: lyrics,
            customLyrics: custom
        )
    }

    private func mergeCustomLyrics(_ imported: [String: LegacyCustomLyrics]) -> Int {
        guard !imported.isEmpty else { return 0 }
        var stored = preferences.getJSON(
            "lyrics.selections.v1",
            as: [String: ImportedSelection].self
        ) ?? [:]
        let changedAt = now().timeIntervalSince1970
        for (songKey, bodies) in imported {
            var selection = stored[songKey] ?? ImportedSelection(
                key: songKey,
                changedAt: changedAt
            )
            if let lyrics = bodies.lyrics { selection.lyrics = lyrics }
            if let romaji = bodies.romaji { selection.romaji = romaji }
            selection.changedAt = max(selection.changedAt, changedAt)
            stored[songKey] = selection
        }
        if stored.count > CustomLyricsSelection.maxRemembered {
            let keep = stored.sorted {
                if $0.value.changedAt == $1.value.changedAt { return $0.key < $1.key }
                return $0.value.changedAt > $1.value.changedAt
            }.prefix(CustomLyricsSelection.maxRemembered)
            stored = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        try? preferences.setJSON(stored, for: "lyrics.selections.v1")
        return imported.count
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func cacheRows(from value: Any?) -> [[String: Any]] {
        guard let value else { return [] }
        if let string = value as? String,
            let data = string.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
        {
            return cacheRows(from: decoded)
        }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        guard let dictionary = value as? [String: Any] else { return [] }
        if let state = dictionary["state"] { return cacheRows(from: state) }
        if let items = dictionary["items"] { return cacheRows(from: items) }
        return dictionary.compactMap { key, item in
            guard var row = item as? [String: Any] else { return nil }
            row["key"] = row["key"] ?? key
            return row
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func milliseconds(_ value: Any?) -> Int? {
        integer(value)
    }

    private static func jsonString(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty,
            let data = try? JSONEncoder().encode(values)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func nativeAudioExists(songId: String) -> Bool {
        let cacheId = AudioCacheUtils.cacheId(for: songId)
        var directories: [URL] = []
        if let current = try? AudioCacheUtils.cacheDirectoryURL(createIfNeeded: false) {
            directories.append(current)
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            directories.append(
                support
                    .appendingPathComponent("Aonsoku", isDirectory: true)
                    .appendingPathComponent("AudioCache", isDirectory: true)
            )
        }
        for directory in Set(directories) {
            let metadataURL = directory.appendingPathComponent("\(cacheId).json")
            guard let data = try? Data(contentsOf: metadataURL),
                let metadata = try? JSONDecoder().decode(
                    NativeCachedAudioFileMetadata.self,
                    from: data
                ),
                metadata.songId == songId
            else { continue }
            let fileURL = directory.appendingPathComponent(metadata.fileName)
            if FileManager.default.fileExists(atPath: fileURL.path) { return true }
        }
        return false
    }

    // MARK: WebKit

    private static func readWebData() async throws -> String {
        #if canImport(WebKit)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let schemeHandler = EmptyCapacitorSchemeHandler()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "capacitor")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: URL(string: "capacitor://localhost/")!))
        while webView.isLoading {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        let value = try await webView.callAsyncJavaScript(
            legacyReadScript,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let json = value as? String else { throw LegacyImportError.invalidPayload }
        return json
        #else
        throw LegacyImportError.unavailable
        #endif
    }

    #if canImport(WebKit)
    private static let legacyReadScript = #"""
    const readEntries = async (databaseName, storeName) => {
      return await new Promise((resolve, reject) => {
        const request = indexedDB.open(databaseName);
        request.onerror = () => reject(request.error || new Error("open failed"));
        request.onupgradeneeded = () => {};
        request.onsuccess = () => {
          const database = request.result;
          if (!database.objectStoreNames.contains(storeName)) {
            database.close();
            resolve([]);
            return;
          }
          const transaction = database.transaction(storeName, "readonly");
          const store = transaction.objectStore(storeName);
          const result = [];
          const cursor = store.openCursor();
          cursor.onerror = () => reject(cursor.error || new Error("cursor failed"));
          cursor.onsuccess = () => {
            const current = cursor.result;
            if (!current) return;
            result.push({ key: current.key, value: current.value });
            current.continue();
          };
          transaction.oncomplete = () => {
            database.close();
            resolve(result);
          };
          transaction.onerror = () => reject(transaction.error || new Error("read failed"));
          transaction.onabort = () => reject(transaction.error || new Error("read aborted"));
        };
      });
    };

    const values = async (databaseName, storeName) =>
      (await readEntries(databaseName, storeName)).map((entry) => entry.value);

    const [cacheMeta, lyrics, cacheStore, offlineStore, customLyrics] =
      await Promise.all([
        values("aonsoku-library", "cacheMeta"),
        values("aonsoku-library", "lyrics"),
        readEntries("aonsoku-cache", "cache-index"),
        readEntries("aonsoku-offline", "offline-library"),
        readEntries("aonsoku-custom-lyrics", "lyrics"),
      ]);
    return JSON.stringify({ cacheMeta, lyrics, cacheStore, offlineStore, customLyrics });
    """#
    #endif
}

enum LegacyImportError: Error {
    case unavailable
    case timedOut
    case invalidPayload
}

struct LegacyMappedData {
    var cacheRows: [CacheMetaRecord]
    var lyrics: [LegacyLyric]
    var customLyrics: [String: LegacyCustomLyrics]
}

struct LegacyLyric {
    var songId: String
    var content: String
    var synced: Bool
    var cachedAt: Int
    var lastAccessedAt: Int
}

struct LegacyCustomLyrics {
    var lyrics: String?
    var romaji: String?
}

private struct ImportedSelection: Codable {
    var key: String?
    var serverId: String?
    var title: String?
    var artist: String?
    var lyrics: String?
    var romaji: String?
    var disabled: Bool
    var offset: Double
    var changedAt: TimeInterval

    init(key: String? = nil, changedAt: TimeInterval) {
        self.key = key
        serverId = nil
        title = nil
        artist = nil
        lyrics = nil
        romaji = nil
        disabled = false
        offset = 0
        self.changedAt = changedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decodeIfPresent(String.self, forKey: .key)
        serverId = try values.decodeIfPresent(String.self, forKey: .serverId)
            ?? values.decodeIfPresent(String.self, forKey: .legacyId)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        artist = try values.decodeIfPresent(String.self, forKey: .artist)
        lyrics = try values.decodeIfPresent(String.self, forKey: .lyrics)
        romaji = try values.decodeIfPresent(String.self, forKey: .romaji)
        disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        changedAt = try values.decodeIfPresent(TimeInterval.self, forKey: .changedAt) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(key, forKey: .key)
        try values.encodeIfPresent(serverId, forKey: .serverId)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(artist, forKey: .artist)
        try values.encodeIfPresent(lyrics, forKey: .lyrics)
        try values.encodeIfPresent(romaji, forKey: .romaji)
        try values.encode(disabled, forKey: .disabled)
        try values.encode(offset, forKey: .offset)
        try values.encode(changedAt, forKey: .changedAt)
    }

    enum CodingKeys: String, CodingKey {
        case key
        case serverId
        case legacyId = "id"
        case title
        case artist
        case lyrics
        case romaji
        case disabled
        case offset
        case changedAt = "_changedAt"
    }
}

#if canImport(WebKit)
private final class EmptyCapacitorSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let data = Data("<!doctype html><meta charset=utf-8>".utf8)
        let response = URLResponse(
            url: urlSchemeTask.request.url!,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
