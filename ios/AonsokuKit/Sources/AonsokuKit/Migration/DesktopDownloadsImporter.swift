import Foundation

// Copies the downloads of the Electron desktop app (Aonsoku Desktop) into this
// app's own audio cache.
//
// The desktop app's `AudioCache` holds, per song, `<base64url(songId)>.<ext>`
// and `<base64url(songId)>.json` with `{songId, fileName, contentType,
// lastModifiedAt}` (`electron/main/native/audio/cache.ts`), the same format
// this app writes. The desktop app's folder is only ever read: nothing is
// created, changed, moved or deleted there. Files are cloned (APFS) or copied
// to a temporary file in this app's cache and renamed into place, then the
// metadata is written and the song registered in the cache index as an
// `explicit` download, which is never evicted automatically.

// MARK: - Models

/// What a scan of the desktop app's downloads found.
public struct DesktopDownloadsScan: Equatable, Sendable {
    /// One song whose metadata and audio file are both present and agree.
    public struct Entry: Equatable, Sendable {
        public let songId: String
        /// `base64url(songId)`, which names both files.
        public let cacheId: String
        public let fileName: String
        public let contentType: String
        /// Milliseconds since 1970, as the desktop app wrote it.
        public let lastModifiedAt: Double
        public let sizeBytes: Int64
    }

    public var entries: [Entry]
    /// Metadata files that could not be used: not matching their name,
    /// without a complete audio file, or unreadable.
    public var skipped: Int

    public var songCount: Int { entries.count }
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }
}

public struct DesktopImportProgress: Equatable, Sendable {
    /// Songs dealt with so far (imported, already present, failed).
    public var completed: Int
    public var total: Int
    public var bytesCopied: Int64
    public var totalBytes: Int64

    public var fraction: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 1
    }
}

public struct DesktopImportFailure: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        /// The desktop app's file changed or vanished while it was imported.
        case sourceChanged
        /// The copy came out shorter than the source.
        case incomplete
        case copyFailed
        case metadataFailed
        case indexFailed
        case diskFull
    }

    public let songId: String
    public let reason: Reason
}

public struct DesktopImportResult: Equatable, Sendable {
    /// Songs copied this time.
    public var imported = 0
    /// Songs this app already had (an earlier import, a download or a
    /// streamed copy); streamed or smart copies are now kept as downloads.
    public var alreadyPresent = 0
    public var failures: [DesktopImportFailure] = []
    public var bytesCopied: Int64 = 0
    /// Metadata files in the desktop app's folder that could not be used.
    public var skipped = 0
    public var wasCancelled = false
    /// The disk filled up part-way: the remaining songs were left alone.
    public var ranOutOfSpace = false

    public var failed: Int { failures.count }
    /// Everything that is on this Mac now because of this or an earlier run.
    public var available: Int { imported + alreadyPresent }
}

public enum DesktopImportError: Error, Equatable, Sendable {
    /// This platform has no desktop app data.
    case unavailable
    /// The folder is missing or this app may not read it (a sandboxed app
    /// cannot read another app's `Application Support` folder).
    case sourceUnreadable
    /// The chosen folder is this app's own cache.
    case sourceIsDestination
    /// Fewer bytes are free than the copies need.
    case insufficientSpace(required: Int64, available: Int64)
    /// This app's own cache folder or index could not be used.
    case storageUnavailable
}

// MARK: - Importer

struct DesktopDownloadsImporter {
    typealias Entry = DesktopDownloadsScan.Entry

    let source: DesktopDataLocation
    let storage: StorageLayout
    let index: CacheMetaRepository
    var now: @Sendable () -> Date = { Date() }
    var availableCapacity: @Sendable (URL) -> Int64? = { Self.availableCapacity(at: $0) }
    var transfer: DesktopFileTransfer = .system
    /// Free space that must remain after the copies.
    var reserveBytes: Int64 = 64 * 1_024 * 1_024

    private static let metadataSuffix = ".json"
    private static let temporaryMarker = ".import-"
    private static let temporarySuffix = ".tmp"
    private static let maximumMetadataBytes = 64 * 1_024

    // MARK: Scanning

    /// Lists the songs that can be imported. Reads the desktop folder only.
    func scanAudioCache() throws -> DesktopDownloadsScan {
        let scope = SecurityScope(source.accessURL)
        defer { scope.end() }
        return try scan()
    }

    private func scan() throws -> DesktopDownloadsScan {
        let fileManager = FileManager.default
        let directory = source.audioCacheDirectory
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            // A readable data folder without downloads has simply none yet.
            if Self.isNoSuchFile(error),
               (try? fileManager.contentsOfDirectory(atPath: source.directory.path)) != nil
            {
                return DesktopDownloadsScan(entries: [], skipped: 0)
            }
            throw DesktopImportError.sourceUnreadable
        }

        var entries: [Entry] = []
        var skipped = 0
        for name in names.sorted() where name.hasSuffix(Self.metadataSuffix) {
            // Only `<cacheId>.json`: temporary metadata (`….json.<pid>.<ms>.tmp`)
            // and unrelated files do not match.
            guard let cacheId = Self.cacheId(fromMetadataName: name) else { continue }
            if let entry = validatedEntry(cacheId: cacheId, metadataName: name, directory: directory) {
                entries.append(entry)
            } else {
                skipped += 1
            }
        }
        return DesktopDownloadsScan(entries: entries, skipped: skipped)
    }

    private struct RawMetadata: Decodable {
        let songId: String
        let fileName: String
        let contentType: String
        let lastModifiedAt: Double
    }

    private func validatedEntry(
        cacheId: String,
        metadataName: String,
        directory: URL
    ) -> Entry? {
        let metadataURL = directory.appendingPathComponent(metadataName)
        guard let metadataSize = Self.regularFileSize(at: metadataURL),
              metadataSize > 0, metadataSize <= Self.maximumMetadataBytes,
              let data = try? Data(contentsOf: metadataURL),
              let raw = try? JSONDecoder().decode(RawMetadata.self, from: data)
        else { return nil }

        // The song must be the one the file name stands for (Electron's own
        // reader rejects anything else), and its audio file must be a plain
        // sibling of the same song: never a path that leads elsewhere.
        guard !raw.songId.isEmpty,
              AudioCacheUtils.cacheId(for: raw.songId) == cacheId,
              Self.isAudioFileName(raw.fileName, cacheId: cacheId),
              !raw.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              raw.lastModifiedAt.isFinite, raw.lastModifiedAt >= 0
        else { return nil }

        // An interrupted download leaves only a temporary file, a complete one
        // is renamed into place before its metadata is written.
        guard let size = Self.regularFileSize(
            at: directory.appendingPathComponent(raw.fileName)
        ), size > 0 else { return nil }

        return Entry(
            songId: raw.songId,
            cacheId: cacheId,
            fileName: raw.fileName,
            contentType: raw.contentType,
            lastModifiedAt: raw.lastModifiedAt,
            sizeBytes: size
        )
    }

    // MARK: Planning

    /// What an import of `scan` would do, from the state of this app's cache
    /// and index. Reads only.
    struct Plan: Equatable {
        /// Songs without a usable copy here: their bytes are copied.
        var copies: [Entry] = []
        /// Songs already here but not kept as downloads (streamed or smart
        /// copies, or missing from the index): registered as downloads.
        var promotions: [Entry] = []
        /// Songs that are downloads here already.
        var upToDate = 0

        var copyBytes: Int64 { copies.reduce(0) { $0 + $1.sizeBytes } }
        /// Songs an import changes something for.
        var pendingCount: Int { copies.count + promotions.count }
    }

    func plan(for scan: DesktopDownloadsScan) throws -> Plan {
        let rows = Dictionary(
            try index.getAll(type: CachedItemType.audio.rawValue).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var plan = Plan()
        for entry in scan.entries {
            guard let existing = existingCopy(of: entry) else {
                plan.copies.append(entry)
                continue
            }
            if let row = rows["audio:\(entry.songId)"],
               CacheSource(stored: row.source) == .explicit,
               row.sizeBytes == Int(clamping: existing.size)
            {
                plan.upToDate += 1
            } else {
                plan.promotions.append(entry)
            }
        }
        return plan
    }

    /// The scan and its plan, for showing what an import would do.
    func scanAndPlan() throws -> (scan: DesktopDownloadsScan, plan: Plan) {
        let scope = SecurityScope(source.accessURL)
        defer { scope.end() }
        let scanned = try scan()
        do {
            return (scanned, try plan(for: scanned))
        } catch {
            throw DesktopImportError.storageUnavailable
        }
    }

    // MARK: Importing

    /// Imports everything `scanAudioCache()` finds.
    ///
    /// Idempotent and resumable: a song this app already has is not copied
    /// again, and an interrupted run leaves only completed songs (each one
    /// fully copied and registered) plus temporary files the next run removes.
    /// One song failing does not stop the others. Throws only before the
    /// first copy: the folder cannot be read, or there is not enough space.
    ///
    /// - Parameters:
    ///   - progress: called before the first song and after each one.
    ///   - cancel: polled between songs and between chunks of a copy.
    func importAudioCache(
        progress: (DesktopImportProgress) -> Void = { _ in },
        cancel: () -> Bool = { false }
    ) throws -> DesktopImportResult {
        let scope = SecurityScope(source.accessURL)
        defer { scope.end() }

        let scanned = try scan()
        let destination: URL
        do {
            destination = try AudioCacheUtils.cacheDirectoryURL(
                createIfNeeded: true, layout: storage
            )
        } catch {
            throw DesktopImportError.storageUnavailable
        }
        guard !Self.overlap(destination, source.audioCacheDirectory),
              !Self.overlap(destination, source.directory)
        else { throw DesktopImportError.sourceIsDestination }
        Self.removeStaleTemporaries(in: destination)

        let required: Int64
        do {
            required = try plan(for: scanned).copyBytes
        } catch {
            throw DesktopImportError.storageUnavailable
        }
        if required > 0, let available = availableCapacity(destination),
           available < required + reserveBytes
        {
            throw DesktopImportError.insufficientSpace(
                required: required + reserveBytes, available: available
            )
        }

        var result = DesktopImportResult(skipped: scanned.skipped)
        func report(_ completed: Int) {
            progress(DesktopImportProgress(
                completed: completed,
                total: scanned.entries.count,
                bytesCopied: result.bytesCopied,
                totalBytes: scanned.totalBytes
            ))
        }
        report(0)

        entries: for (offset, entry) in scanned.entries.enumerated() {
            if cancel() {
                result.wasCancelled = true
                break entries
            }
            do {
                switch try process(entry, into: destination, cancel: cancel) {
                case let .imported(bytes):
                    result.imported += 1
                    result.bytesCopied += bytes
                case .alreadyPresent:
                    result.alreadyPresent += 1
                }
            } catch is CancellationError {
                result.wasCancelled = true
                break entries
            } catch {
                let reason = Self.failureReason(for: error)
                result.failures.append(DesktopImportFailure(
                    songId: entry.songId, reason: reason
                ))
                NativeLogger.shared.warn(
                    "desktop import failed song=\(entry.songId) reason=\(reason.rawValue) "
                        + "error=\(Self.diagnostic(for: error))",
                    source: "DesktopImport"
                )
                if reason == .diskFull {
                    result.ranOutOfSpace = true
                    break entries
                }
            }
            report(offset + 1)
        }
        NativeLogger.shared.info(
            "desktop import imported=\(result.imported) present=\(result.alreadyPresent) "
                + "failed=\(result.failed) skipped=\(result.skipped) "
                + "cancelled=\(result.wasCancelled) outOfSpace=\(result.ranOutOfSpace)",
            source: "DesktopImport"
        )
        return result
    }

    private enum Outcome {
        case imported(bytes: Int64)
        case alreadyPresent
    }

    private enum StepFailure: Error {
        case sourceChanged
        case incomplete
        case metadata(Error)
        case index(Error)
    }

    private func process(
        _ entry: Entry,
        into destination: URL,
        cancel: () -> Bool
    ) throws -> Outcome {
        if let existing = existingCopy(of: entry) {
            do { try register(entry, fileSize: existing.size) }
            catch { throw StepFailure.index(error) }
            return .alreadyPresent
        }

        let fileManager = FileManager.default
        let sourceURL = source.audioCacheDirectory
            .appendingPathComponent(entry.fileName, isDirectory: false)
        guard Self.regularFileSize(at: sourceURL) == entry.sizeBytes else {
            throw StepFailure.sourceChanged
        }

        let temporary = destination.appendingPathComponent(
            "\(entry.cacheId)\(Self.temporaryMarker)\(UUID().uuidString)\(Self.temporarySuffix)",
            isDirectory: false
        )
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: temporary) }
        }
        try transfer.copy(sourceURL, temporary, cancel)
        // A regular file of the expected size, and a source that did not
        // change meanwhile (a clone of a link swapped in is not a regular
        // file and is refused here, before anything else touches it).
        guard Self.regularFileSize(at: temporary) == entry.sizeBytes,
              Self.regularFileSize(at: sourceURL) == entry.sizeBytes
        else { throw StepFailure.incomplete }
        // A clone keeps the source's mode, and a read-only source is common.
        try? fileManager.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: temporary.path
        )

        // The audio file first, then its metadata, as every writer of this
        // cache does: a song counts as cached only once its metadata exists.
        let final = destination.appendingPathComponent(entry.fileName, isDirectory: false)
        guard rename(temporary.path, final.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = true

        do {
            let metadata = NativeCachedAudioFileMetadata(
                songId: entry.songId,
                fileName: entry.fileName,
                contentType: entry.contentType,
                lastModifiedAt: entry.lastModifiedAt
            )
            try JSONEncoder().encode(metadata).write(
                to: destination.appendingPathComponent(
                    "\(entry.cacheId)\(Self.metadataSuffix)", isDirectory: false
                ),
                options: .atomic
            )
        } catch {
            throw StepFailure.metadata(error)
        }
        do { try register(entry, fileSize: entry.sizeBytes) }
        catch { throw StepFailure.index(error) }
        return .imported(bytes: entry.sizeBytes)
    }

    /// The copy of `entry` this app already has, if it is usable the way
    /// `AudioService.resolveAudioFile` resolves it.
    private func existingCopy(of entry: Entry) -> (url: URL, size: Int64)? {
        for directory in storage.audioManagedDirectories {
            let metadataURL = directory.appendingPathComponent(
                "\(entry.cacheId)\(Self.metadataSuffix)", isDirectory: false
            )
            guard let data = try? Data(contentsOf: metadataURL),
                  let stored = try? JSONDecoder().decode(
                      NativeCachedAudioFileMetadata.self, from: data
                  ),
                  stored.songId == entry.songId,
                  Self.isPlainFileName(stored.fileName) else { continue }
            let url = directory.appendingPathComponent(stored.fileName, isDirectory: false)
            if let size = Self.regularFileSize(at: url), size > 0 {
                return (url, size)
            }
        }
        return nil
    }

    /// Registers the song as an explicit download. A copy that streaming or a
    /// smart rule cached is promoted, so it is no longer evicted; rows that
    /// already say so are left untouched.
    private func register(_ entry: Entry, fileSize: Int64) throws {
        let key = "audio:\(entry.songId)"
        let timestamp = Int(now().timeIntervalSince1970 * 1_000)
        let size = Int(clamping: fileSize)
        if var row = try index.getByKey(key) {
            let isExplicit = CacheSource(stored: row.source) == .explicit
            guard !isExplicit || row.sizeBytes != size else { return }
            if !isExplicit {
                row.source = CacheSource.explicit.rawValue
                row.lastAccessedAt = timestamp
            }
            row.sizeBytes = size
            try index.upsert(row)
            return
        }
        // The date it was downloaded on the desktop, when that makes sense.
        let downloaded = Int(entry.lastModifiedAt)
        try index.upsert(CacheMetaRecord(
            key: key,
            id: entry.songId,
            type: CachedItemType.audio.rawValue,
            source: CacheSource.explicit.rawValue,
            triggersJson: nil,
            coverSize: nil,
            sizeBytes: size,
            cachedAt: downloaded > 0 && downloaded <= timestamp ? downloaded : timestamp,
            lastAccessedAt: timestamp,
            removedFromServer: false
        ))
    }

    // MARK: Helpers

    /// `<cacheId>.json` → `<cacheId>`, for names that can belong to the cache.
    static func cacheId(fromMetadataName name: String) -> String? {
        guard name.hasSuffix(metadataSuffix) else { return nil }
        let cacheId = String(name.dropLast(metadataSuffix.count))
        guard !cacheId.isEmpty, cacheId.unicodeScalars.allSatisfy({
            ($0.value >= 0x30 && $0.value <= 0x39) // 0-9
                || ($0.value >= 0x41 && $0.value <= 0x5A) // A-Z
                || ($0.value >= 0x61 && $0.value <= 0x7A) // a-z
                || $0 == "-" || $0 == "_"
        }) else { return nil }
        return cacheId
    }

    /// `<cacheId>.<ext>` with a single alphanumeric extension that is not
    /// metadata or a temporary file.
    static func isAudioFileName(_ name: String, cacheId: String) -> Bool {
        guard isPlainFileName(name), name.hasPrefix("\(cacheId).") else { return false }
        let ext = String(name.dropFirst(cacheId.count + 1))
        guard !ext.isEmpty, ext.count <= 8, ext.unicodeScalars.allSatisfy({
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
        }) else { return false }
        return !["json", "tmp"].contains(ext.lowercased())
    }

    /// A single path component: no separators, no navigation, no control
    /// characters.
    static func isPlainFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else {
            return false
        }
        return !name.unicodeScalars.contains {
            $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F
        }
    }

    /// The size of a regular file that is not a symbolic link, nil otherwise.
    static func regularFileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isSymbolicLink != true, values.isRegularFile == true,
            let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func overlap(_ first: URL, _ second: URL) -> Bool {
        let a = first.resolvingSymlinksInPath().standardizedFileURL.path
        let b = second.resolvingSymlinksInPath().standardizedFileURL.path
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// Removes what an interrupted run left in this app's own cache.
    static func removeStaleTemporaries(in directory: URL) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.contains(temporaryMarker) && name.hasSuffix(temporarySuffix) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    private static func failureReason(for error: Error) -> DesktopImportFailure.Reason {
        if let step = error as? StepFailure {
            switch step {
            case .sourceChanged: return .sourceChanged
            case .incomplete: return .incomplete
            case let .metadata(underlying):
                return isOutOfSpace(underlying) ? .diskFull : .metadataFailed
            case .index: return .indexFailed
            }
        }
        return isOutOfSpace(error) ? .diskFull : .copyFailed
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isOutOfSpace(underlying)
        }
        return false
    }

    static func isNoSuchFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) { return true }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoSuchFile.rawValue
            || nsError.code == CocoaError.fileNoSuchFile.rawValue { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNoSuchFile(underlying)
        }
        return false
    }

    /// Error domain and code only: descriptions can carry paths.
    private static func diagnostic(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)/\(nsError.code)"
    }
}

// MARK: - Access

/// Keeps the access an open panel granted to a picked folder alive. A no-op
/// for URLs that are not security-scoped, and nothing is persisted.
private struct SecurityScope {
    let url: URL
    let started: Bool

    init(_ url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }

    func end() {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

// MARK: - Copying

/// How a file reaches this app's cache. Replaceable in tests.
struct DesktopFileTransfer: Sendable {
    /// Writes a copy of `source` at the not yet existing `destination` and
    /// never touches `source`. Checks `isCancelled` between chunks.
    var copy: @Sendable (_ source: URL, _ destination: URL, _ isCancelled: () -> Bool) throws -> Void

    static let system = DesktopFileTransfer { source, destination, isCancelled in
        try DesktopFileCopier.copy(from: source, to: destination, isCancelled: isCancelled)
    }
}

enum DesktopFileCopier {
    static func copy(from source: URL, to destination: URL, isCancelled: () -> Bool) throws {
        if clone(from: source, to: destination) { return }
        try stream(from: source, to: destination, isCancelled: isCancelled)
    }

    /// An APFS clone: instant, and it takes no extra space until one side
    /// changes. Fails (and the caller copies) across volumes and on file
    /// systems without clones.
    static func clone(from source: URL, to destination: URL) -> Bool {
        // CLONE_NOFOLLOW: never follow a symbolic link planted at the source.
        clonefile(source.path, destination.path, 0x0001) == 0
    }

    /// A plain copy in 1 MiB chunks, with the cancellation point a clone
    /// does not need.
    static func stream(
        from source: URL,
        to destination: URL,
        isCancelled: () -> Bool
    ) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw posixError() }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw posixError() }
        var finished = false
        defer {
            close(output)
            if !finished { unlink(destination.path) }
        }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            if isCancelled() { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress! + written, count - written)
                }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                written += result
            }
        }
        // Durable before the rename that publishes it.
        guard fsync(output) == 0 else { throw posixError() }
        finished = true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
