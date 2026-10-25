import Foundation
import Observation

/// Lyrics for the playing song (web `src/service/lyrics.ts`): sources in the
/// configured priority, the custom lyrics server, per-song candidate
/// selection, hiding and timing offset.
///
/// Selections are stored under `lyrics.selections.v1`, keyed by the song key
/// (`[path, artist, title, album].joined("\u{1F}")`), at most 50 songs.
@MainActor
@Observable
public final class LyricsStore {
    /// The loading state for `songId`.
    public private(set) var state = LyricsLoadState.idle
    /// The song `state` belongs to.
    public private(set) var songId: String?
    /// The current song's selection; `.init()` when it has none.
    public private(set) var selection = CustomLyricsSelection()

    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public let preferences: PreferencesService
    /// The signed-in server type, for the LMS artist rule.
    @ObservationIgnored public var serverType: @MainActor () -> String? = { nil }
    @ObservationIgnored public var urlSession: URLSession = .shared

    @ObservationIgnored private var currentSong: Song?
    @ObservationIgnored private var currentSongKey: String?
    @ObservationIgnored private var inFlight: [String: InFlightLoad] = [:]
    @ObservationIgnored private var memoryCache: [String: MemoryEntry] = [:]
    @ObservationIgnored private var memoryOrder: [String] = []
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private let cachedLyrics: (String) throws -> LibraryLyrics?
    @ObservationIgnored private let storeCachedLyrics: (String, String, Bool) throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let appVersion: () -> String

    private static let selectionsKey = "lyrics.selections.v1"
    private static let memoryLimit = 24

    public init(
        api: any SubsonicAPI,
        library: LibraryService,
        settings: SettingsStore,
        preferences: PreferencesService
    ) {
        self.api = api
        self.library = library
        self.settings = settings
        self.preferences = preferences
        cachedLyrics = { try library.lyrics(songId: $0) }
        storeCachedLyrics = { try library.storeLyrics(songId: $0, content: $1, synced: $2) }
        now = Date.init
        appVersion = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown"
        }
    }

    init(
        api: any SubsonicAPI,
        library: LibraryService,
        settings: SettingsStore,
        preferences: PreferencesService,
        cachedLyrics: @escaping (String) throws -> LibraryLyrics?,
        storeCachedLyrics: @escaping (String, String, Bool) throws -> Void,
        now: @escaping () -> Date = Date.init,
        appVersion: @escaping () -> String = { "test" }
    ) {
        self.api = api
        self.library = library
        self.settings = settings
        self.preferences = preferences
        self.cachedLyrics = cachedLyrics
        self.storeCachedLyrics = storeCachedLyrics
        self.now = now
        self.appVersion = appVersion
    }

    /// Loads lyrics for `song` unless they are already loaded or loading.
    /// nil clears the state.
    public func load(for song: Song?) async {
        await load(for: song, bypassingMemory: false)
    }

    public func reset() {
        for load in inFlight.values { load.task.cancel() }
        inFlight.removeAll()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        currentSong = nil
        currentSongKey = nil
        songId = nil
        selection = CustomLyricsSelection()
        state = .idle
        revision = UUID()
    }

    /// Loads again, bypassing the in-memory cache.
    public func reload() async {
        guard let currentSong else { return }
        memoryCache.removeValue(forKey: currentSong.id)
        memoryOrder.removeAll { $0 == currentSong.id }
        inFlight[currentSong.id]?.task.cancel()
        inFlight.removeValue(forKey: currentSong.id)
        await load(for: currentSong, bypassingMemory: true)
    }

    /// The line to highlight at a playback position, with the offset applied.
    public func lineIndex(at position: TimeInterval) -> Int? {
        state.lyrics?.lineIndex(at: position + selection.offset)
    }

    /// Searches the custom lyrics server. Empty when it is not configured.
    public func searchCandidates(
        title: String,
        artist: String
    ) async throws -> [CustomLyricsCandidate] {
        let lyricsSettings = settings.settings.lyrics
        guard lyricsSettings.customServerEnabled,
            !lyricsSettings.customServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return try await requestCustomCandidates(
            baseURL: lyricsSettings.customServerUrl,
            password: lyricsSettings.customServerPassword,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: nil,
            duration: nil,
            path: nil,
            paginated: false
        )
    }

    /// Uses `candidate` for the current song and reloads.
    public func select(_ candidate: CustomLyricsCandidate) async {
        guard currentSongKey != nil else { return }
        selection = CustomLyricsSelection(
            key: candidate.id,
            serverId: candidate.serverId,
            title: candidate.title,
            artist: candidate.artist,
            lyrics: candidate.lyrics,
            romaji: candidate.romaji,
            disabled: selection.disabled,
            offset: selection.offset
        )
        persistCurrentSelection()
        await reload()
    }

    /// Returns the current song to automatic sources, keeping its offset.
    public func resetSelection() async {
        guard currentSongKey != nil else { return }
        selection = CustomLyricsSelection(
            disabled: selection.disabled,
            offset: selection.offset
        )
        persistCurrentSelection()
        await reload()
    }

    /// Hides or shows lyrics for the current song.
    public func setDisabled(_ disabled: Bool) async {
        guard currentSongKey != nil, selection.disabled != disabled else { return }
        selection.disabled = disabled
        persistCurrentSelection()
        if disabled {
            inFlight[songId ?? ""]?.task.cancel()
            state = .disabled
        } else {
            await reload()
        }
    }

    /// Seconds added to the playback position, clamped to
    /// `CustomLyricsSelection.offsetRange`.
    public func setOffset(_ offset: Double) {
        guard currentSongKey != nil else { return }
        let clamped = min(
            max(offset, CustomLyricsSelection.offsetRange.lowerBound),
            CustomLyricsSelection.offsetRange.upperBound
        )
        let rounded =
            (clamped / CustomLyricsSelection.offsetStep).rounded()
            * CustomLyricsSelection.offsetStep
        let normalized = abs(rounded) < 0.000_001 ? 0 : rounded
        guard selection.offset != normalized else { return }
        selection.offset = normalized
        persistCurrentSelection()
    }

    private func load(for song: Song?, bypassingMemory: Bool) async {
        guard let song else {
            for load in inFlight.values { load.task.cancel() }
            inFlight.removeAll()
            currentSong = nil
            currentSongKey = nil
            songId = nil
            selection = CustomLyricsSelection()
            state = .idle
            revision = UUID()
            return
        }

        let key = Self.songKey(song)
        let storedSelection = readSelections()[key]?.selection ?? CustomLyricsSelection()
        if songId == song.id, currentSongKey == key, !bypassingMemory {
            switch state {
            case .loaded, .disabled:
                return
            default:
                break
            }
            if let existing = inFlight[song.id] {
                let result = await existing.task.value
                finish(result, song: song, key: key, token: existing.token)
                return
            }
        }

        if songId != song.id || currentSongKey != key {
            if let previous = songId { inFlight[previous]?.task.cancel() }
        }
        currentSong = song
        currentSongKey = key
        songId = song.id
        selection = storedSelection
        let loadRevision = UUID()
        revision = loadRevision

        if storedSelection.disabled {
            state = .disabled
            return
        }

        if !bypassingMemory,
            let cached = memoryCache[song.id],
            cached.selectionKey == storedSelection.key,
            let lyrics = render(cached.envelope, for: song)
        {
            touchMemory(song.id)
            state = .loaded(lyrics)
            return
        }

        state = .loading
        let token = UUID()
        let lyricsSettings = settings.settings.lyrics
        let privacy = settings.settings.privacy
        let signedInServerType = serverType()
        let task = Task { [weak self] () -> LoadResolution in
            guard let self else { return .unavailable }
            return await resolve(
                song: song,
                selection: storedSelection,
                lyricsSettings: lyricsSettings,
                lrcLibEnabled: privacy.lrcLibEnabled,
                serverType: signedInServerType
            )
        }
        inFlight[song.id] = InFlightLoad(token: token, task: task)
        let result = await task.value
        guard revision == loadRevision else { return }
        finish(result, song: song, key: key, token: token)
    }

    private func finish(
        _ result: LoadResolution,
        song: Song,
        key: String,
        token: UUID
    ) {
        guard inFlight[song.id]?.token == token else { return }
        inFlight.removeValue(forKey: song.id)
        guard songId == song.id, currentSongKey == key, !selection.disabled else { return }
        switch result {
        case .loaded(let envelope):
            guard let lyrics = render(envelope, for: song) else {
                state = .unavailable
                return
            }
            putMemory(envelope, songId: song.id, selectionKey: selection.key)
            state = .loaded(lyrics)
        case .unavailable:
            state = .unavailable
        }
    }

    private func resolve(
        song: Song,
        selection: CustomLyricsSelection,
        lyricsSettings: LyricsSettings,
        lrcLibEnabled: Bool,
        serverType: String?
    ) async -> LoadResolution {
        if let selectedKey = selection.key {
            if let raw = selection.lyrics?.trimmedNonempty {
                let envelope = CachedLyricsEnvelope(
                    source: .custom,
                    raw: raw,
                    romaji: selection.romaji?.trimmedNonempty,
                    selectionKey: selectedKey
                )
                cache(envelope, for: song)
                return .loaded(envelope)
            }
            let outcome = await custom(
                song: song,
                settings: lyricsSettings,
                selectedKey: selectedKey
            )
            switch outcome {
            case .found(let envelope):
                cache(envelope, for: song)
                return .loaded(envelope)
            case .connectivityFailure:
                if let cached = diskCache(for: song, selectionKey: selectedKey) {
                    return .loaded(cached)
                }
            case .missing:
                break
            }
            return .unavailable
        }

        var enabled: [LyricsSource] = []
        for source in LyricsSettings.normalizedPriority(lyricsSettings.sourcePriority) {
            if source == .lrclib, !lrcLibEnabled { continue }
            if source == .custom,
                !lyricsSettings.customServerEnabled
                    || lyricsSettings.customServerUrl
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                continue
            }
            enabled.append(source)
        }

        var firstUnsynced: CachedLyricsEnvelope?
        var connectivityFailures = 0
        for source in enabled {
            if Task.isCancelled { return .unavailable }
            let outcome: SourceOutcome
            switch source {
            case .navidrome:
                outcome = await navidrome(
                    song: song,
                    preferSynced: lyricsSettings.preferSyncedLyrics
                )
            case .lrclib:
                outcome = await lrcLib(song: song, serverType: serverType)
            case .custom:
                outcome = await custom(song: song, settings: lyricsSettings, selectedKey: nil)
            }
            switch outcome {
            case .found(let envelope):
                if !lyricsSettings.preferSyncedLyrics || envelope.isSynced {
                    cache(envelope, for: song)
                    return .loaded(envelope)
                }
                if firstUnsynced == nil { firstUnsynced = envelope }
            case .connectivityFailure:
                connectivityFailures += 1
            case .missing:
                break
            }
        }

        if let firstUnsynced {
            cache(firstUnsynced, for: song)
            return .loaded(firstUnsynced)
        }
        if !enabled.isEmpty, connectivityFailures == enabled.count,
            let cached = diskCache(for: song, selectionKey: nil)
        {
            return .loaded(cached)
        }
        return .unavailable
    }

    private func navidrome(
        song: Song,
        preferSynced: Bool
    ) async -> SourceOutcome {
        var connectivityFailure = false
        var structuredFallback: CachedLyricsEnvelope?
        do {
            let tracks = try await api.lyricsBySongId(song.id)
            if !tracks.isEmpty {
                let envelope = CachedLyricsEnvelope(source: .navidrome, structured: tracks)
                if !preferSynced || envelope.isSynced { return .found(envelope) }
                structuredFallback = envelope
            }
        } catch {
            if Self.isConnectivity(error) { connectivityFailure = true }
            if Self.isCancellation(error) { return .missing }
        }

        do {
            if let plain = try await api.lyrics(artist: song.artist, title: song.title),
                let raw = plain.value.trimmedNonempty
            {
                let envelope = CachedLyricsEnvelope(source: .navidrome, raw: raw)
                if envelope.isSynced || structuredFallback == nil { return .found(envelope) }
            }
        } catch {
            if Self.isConnectivity(error) { connectivityFailure = true }
            if Self.isCancellation(error) { return .missing }
        }
        if let structuredFallback { return .found(structuredFallback) }
        return connectivityFailure ? .connectivityFailure : .missing
    }

    private func lrcLib(song: Song, serverType: String?) async -> SourceOutcome {
        guard var components = URLComponents(string: "https://lrclib.net/api/get") else {
            return .missing
        }
        components.queryItems = [
            URLQueryItem(
                name: "artist_name", value: Self.artist(for: song, serverType: serverType)),
            URLQueryItem(name: "track_name", value: song.title),
            song.album.trimmedNonempty.map { URLQueryItem(name: "album_name", value: $0) },
            song.duration > 0
                ? URLQueryItem(name: "duration", value: String(song.duration))
                : nil,
        ].compactMap { $0 }
        guard let url = components.url else { return .missing }
        var request = URLRequest(url: url)
        let client = "Aonsoku v\(appVersion()) (https://github.com/realtvop/aonsoku-reborn)"
        request.setValue(client, forHTTPHeaderField: "Lrclib-Client")
        request.setValue(client, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard Self.isSuccessful(response) else {
                return Self.isConnectivity(response) ? .connectivityFailure : .missing
            }
            let payload = try JSONDecoder().decode(LRCLibResponse.self, from: data)
            if let synced = payload.syncedLyrics?.trimmedNonempty {
                return .found(CachedLyricsEnvelope(source: .lrclib, raw: synced))
            }
            if let plain = payload.plainLyrics?.trimmedNonempty {
                return .found(CachedLyricsEnvelope(source: .lrclib, raw: plain))
            }
            return .missing
        } catch {
            if Self.isCancellation(error) { return .missing }
            return Self.isConnectivity(error) ? .connectivityFailure : .missing
        }
    }

    private func custom(
        song: Song,
        settings: LyricsSettings,
        selectedKey: String?
    ) async -> SourceOutcome {
        guard settings.customServerEnabled,
            !settings.customServerUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .missing }
        do {
            let response = try await requestCustomResponse(
                baseURL: settings.customServerUrl,
                password: settings.customServerPassword,
                title: song.title,
                artist: song.artist,
                album: song.album,
                duration: song.duration > 0 ? TimeInterval(song.duration) : nil,
                path: song.path,
                paginated: true
            )
            switch response {
            case .candidates(let candidates):
                let candidate =
                    selectedKey.flatMap { key in
                        candidates.first { $0.id == key || $0.serverId == key }
                    } ?? (selectedKey == nil ? candidates.first : nil)
                guard let candidate else { return .missing }
                return .found(
                    CachedLyricsEnvelope(
                        source: .custom,
                        raw: candidate.lyrics,
                        romaji: candidate.romaji?.trimmedNonempty,
                        selectionKey: selectedKey
                    ))
            case .text(let text):
                guard selectedKey == nil, let raw = text.trimmedNonempty else { return .missing }
                return .found(CachedLyricsEnvelope(source: .custom, raw: raw))
            }
        } catch {
            if Self.isCancellation(error) { return .missing }
            return Self.isConnectivity(error) ? .connectivityFailure : .missing
        }
    }

    private func requestCustomCandidates(
        baseURL: String,
        password: String,
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?,
        path: String?,
        paginated: Bool
    ) async throws -> [CustomLyricsCandidate] {
        switch try await requestCustomResponse(
            baseURL: baseURL,
            password: password,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            path: path,
            paginated: paginated
        ) {
        case .candidates(let candidates): candidates
        case .text: []
        }
    }

    private func requestCustomResponse(
        baseURL: String,
        password: String,
        title: String,
        artist: String,
        album: String?,
        duration: TimeInterval?,
        path: String?,
        paginated: Bool
    ) async throws -> CustomResponse {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedURL) else {
            throw URLError(.badURL)
        }
        var query = components.queryItems ?? []
        if let title = title.trimmedNonempty {
            query.append(URLQueryItem(name: "title", value: title))
        }
        if let artist = artist.trimmedNonempty {
            query.append(URLQueryItem(name: "artist", value: artist))
        }
        if let album = album?.trimmedNonempty {
            query.append(URLQueryItem(name: "album", value: album))
        }
        if let duration {
            query.append(URLQueryItem(name: "duration", value: Self.number(duration)))
        }
        if let path = path?.trimmedNonempty {
            query.append(URLQueryItem(name: "path", value: path))
        }
        if paginated {
            query.append(URLQueryItem(name: "offset", value: "0"))
            query.append(URLQueryItem(name: "limit", value: "10"))
        }
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if let password = password.trimmedNonempty {
            request.setValue(password, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard Self.isSuccessful(response) else {
            throw LyricsHTTPError(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let contentType =
            (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("application/json") {
            let raw = try JSONDecoder().decode([CustomCandidateResponse].self, from: data)
            let candidates = raw.enumerated().compactMap { index, item in
                item.candidate(index: index)
            }
            return .candidates(candidates)
        }
        return .text(String(data: data, encoding: .utf8) ?? "")
    }

    private func render(_ envelope: CachedLyricsEnvelope, for song: Song) -> SongLyrics? {
        let showTranslation = settings.settings.lyrics.showTranslation
        if let structured = envelope.structured {
            return LyricsParser.structured(
                structured,
                duration: TimeInterval(song.duration),
                source: envelope.source,
                showTranslation: showTranslation
            )
        }
        guard let raw = envelope.raw?.trimmedNonempty else { return nil }
        if envelope.isSynced {
            return LyricsParser.lrc(
                raw,
                duration: TimeInterval(song.duration),
                romaji: envelope.romaji,
                source: envelope.source,
                credit: envelope.credit,
                showTranslation: showTranslation
            )
        }
        return LyricsParser.plain(raw, source: envelope.source, credit: envelope.credit)
    }

    private func cache(_ envelope: CachedLyricsEnvelope, for song: Song) {
        guard let data = try? JSONEncoder().encode(envelope),
            let content = String(data: data, encoding: .utf8)
        else { return }
        try? storeCachedLyrics(song.id, content, envelope.isSynced)
    }

    private func diskCache(for song: Song, selectionKey: String?) -> CachedLyricsEnvelope? {
        guard let stored = try? cachedLyrics(song.id) else { return nil }
        if let data = stored.content.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(CachedLyricsEnvelope.self, from: data),
            envelope.selectionKey == selectionKey
        {
            return envelope
        }
        guard selectionKey == nil else { return nil }
        if let data = stored.content.data(using: .utf8),
            let tracks = try? JSONDecoder().decode([CachedStructuredLyrics].self, from: data),
            !tracks.isEmpty
        {
            return CachedLyricsEnvelope(
                source: .navidrome,
                structured: tracks.map(\.value)
            )
        }
        guard let raw = stored.content.trimmedNonempty else { return nil }
        return CachedLyricsEnvelope(source: .navidrome, raw: raw, synced: stored.synced)
    }

    private func putMemory(
        _ envelope: CachedLyricsEnvelope,
        songId: String,
        selectionKey: String?
    ) {
        memoryCache[songId] = MemoryEntry(envelope: envelope, selectionKey: selectionKey)
        touchMemory(songId)
        while memoryOrder.count > Self.memoryLimit {
            memoryCache.removeValue(forKey: memoryOrder.removeFirst())
        }
    }

    private func touchMemory(_ songId: String) {
        memoryOrder.removeAll { $0 == songId }
        memoryOrder.append(songId)
    }

    private func readSelections() -> [String: StoredSelection] {
        preferences.getJSON(Self.selectionsKey, as: [String: StoredSelection].self) ?? [:]
    }

    private func persistCurrentSelection() {
        guard let currentSongKey else { return }
        var selections = readSelections()
        if selection.isDefault {
            selections.removeValue(forKey: currentSongKey)
        } else {
            selections[currentSongKey] = StoredSelection(
                selection: selection,
                changedAt: now().timeIntervalSince1970
            )
        }
        while selections.count > CustomLyricsSelection.maxRemembered,
            let oldest = selections.min(by: {
                if $0.value.changedAt == $1.value.changedAt { return $0.key < $1.key }
                return $0.value.changedAt < $1.value.changedAt
            })?.key
        {
            selections.removeValue(forKey: oldest)
        }
        if selections.isEmpty {
            preferences.remove(Self.selectionsKey)
        } else {
            try? preferences.setJSON(selections, for: Self.selectionsKey)
        }
        if let currentSong {
            memoryCache.removeValue(forKey: currentSong.id)
            memoryOrder.removeAll { $0 == currentSong.id }
        }
    }

    private static func songKey(_ song: Song) -> String {
        [song.path ?? "", song.artist, song.title, song.album].joined(separator: "\u{1F}")
    }

    private static func artist(for song: Song, serverType: String?) -> String {
        guard serverType?.lowercased() == "lms" else { return song.artist }
        return song.artist.split(separator: ",", maxSplits: 1)
            .first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? song.artist
    }

    private static func number(_ value: TimeInterval) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func isSuccessful(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return true }
        return (200..<300).contains(response.statusCode)
    }

    private static func isConnectivity(_ response: URLResponse) -> Bool {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return status == 408 || status == 429 || status >= 500
    }

    private static func isConnectivity(_ error: any Error) -> Bool {
        if let error = error as? SubsonicAPIError { return error.isConnectivityFailure }
        if let error = error as? LyricsHTTPError {
            return error.status == 408 || error.status == 429 || error.status >= 500
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .cancelled, .badURL, .unsupportedURL, .badServerResponse:
            return false
        default:
            return true
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || (error as? SubsonicAPIError) == .cancelled
    }
}

extension LyricsStore {
    fileprivate struct InFlightLoad {
        var token: UUID
        var task: Task<LoadResolution, Never>
    }

    fileprivate struct MemoryEntry {
        var envelope: CachedLyricsEnvelope
        var selectionKey: String?
    }

    fileprivate enum LoadResolution: Sendable {
        case loaded(CachedLyricsEnvelope)
        case unavailable
    }

    fileprivate enum SourceOutcome: Sendable {
        case found(CachedLyricsEnvelope)
        case missing
        case connectivityFailure
    }

    fileprivate enum CustomResponse {
        case candidates([CustomLyricsCandidate])
        case text(String)
    }

    fileprivate struct LRCLibResponse: Decodable {
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    fileprivate struct LyricsHTTPError: Error {
        var status: Int
    }

    fileprivate struct CustomCandidateResponse: Decodable {
        var serverId: String?
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var isSynced: Bool?
        var lyrics: String?
        var romaji: String?

        enum CodingKeys: String, CodingKey {
            case serverId = "id"
            case title
            case artist
            case album
            case duration
            case isSynced
            case synced
            case lyrics
            case romaji
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? values.decode(String.self, forKey: .serverId) {
                serverId = value
            } else if let value = try? values.decode(Int.self, forKey: .serverId) {
                serverId = String(value)
            }
            title = try? values.decode(String.self, forKey: .title)
            artist = try? values.decode(String.self, forKey: .artist)
            album = try? values.decode(String.self, forKey: .album)
            if let value = try? values.decode(Double.self, forKey: .duration) {
                duration = value
            } else if let value = try? values.decode(String.self, forKey: .duration) {
                duration = Double(value)
            }
            isSynced =
                (try? values.decode(Bool.self, forKey: .isSynced))
                ?? (try? values.decode(Bool.self, forKey: .synced))
            lyrics = try? values.decode(String.self, forKey: .lyrics)
            romaji = try? values.decode(String.self, forKey: .romaji)
        }

        func candidate(index: Int) -> CustomLyricsCandidate? {
            guard let lyrics = lyrics?.trimmedNonempty else { return nil }
            let title = title ?? ""
            let artist = artist ?? ""
            return CustomLyricsCandidate(
                id: serverId?.trimmedNonempty ?? "\(index):\(artist):\(title)",
                serverId: serverId?.trimmedNonempty,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                isSynced: isSynced ?? LyricsParser.isSynced(lyrics),
                lyrics: lyrics,
                romaji: romaji
            )
        }
    }

    fileprivate struct CachedLyricsEnvelope: Codable, Sendable {
        var version = 1
        var source: LyricsSource
        var raw: String?
        var romaji: String?
        var structured: [SubsonicStructuredLyrics]?
        var credit: String?
        var selectionKey: String?
        private var synced: Bool?

        init(
            source: LyricsSource,
            raw: String? = nil,
            romaji: String? = nil,
            structured: [SubsonicStructuredLyrics]? = nil,
            credit: String? = nil,
            selectionKey: String? = nil,
            synced: Bool? = nil
        ) {
            self.source = source
            self.raw = raw
            self.romaji = romaji
            self.structured = structured
            self.credit = credit
            self.selectionKey = selectionKey
            self.synced = synced
        }

        var isSynced: Bool {
            structured?.first?.synced ?? synced ?? raw.map(LyricsParser.isSynced) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case version
            case source
            case raw
            case romaji
            case structured
            case credit
            case selectionKey
            case synced
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            source = try values.decode(LyricsSource.self, forKey: .source)
            raw = try values.decodeIfPresent(String.self, forKey: .raw)
            romaji = try values.decodeIfPresent(String.self, forKey: .romaji)
            structured = try values.decodeIfPresent(
                [CachedStructuredLyrics].self,
                forKey: .structured
            )?.map(\.value)
            credit = try values.decodeIfPresent(String.self, forKey: .credit)
            selectionKey = try values.decodeIfPresent(String.self, forKey: .selectionKey)
            synced = try values.decodeIfPresent(Bool.self, forKey: .synced)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(source, forKey: .source)
            try values.encodeIfPresent(raw, forKey: .raw)
            try values.encodeIfPresent(romaji, forKey: .romaji)
            try values.encodeIfPresent(
                structured?.map(CachedStructuredLyrics.init),
                forKey: .structured
            )
            try values.encodeIfPresent(credit, forKey: .credit)
            try values.encodeIfPresent(selectionKey, forKey: .selectionKey)
            try values.encodeIfPresent(synced, forKey: .synced)
        }
    }

    fileprivate struct CachedStructuredLyrics: Codable, Sendable {
        struct Line: Codable, Sendable {
            var start: Int?
            var value: String
        }

        var lang: String
        var synced: Bool
        var offset: Int
        var displayArtist: String?
        var displayTitle: String?
        var lines: [Line]

        init(_ value: SubsonicStructuredLyrics) {
            lang = value.lang
            synced = value.synced
            offset = value.offset
            displayArtist = value.displayArtist
            displayTitle = value.displayTitle
            lines = value.lines.map { Line(start: $0.start, value: $0.value) }
        }

        var value: SubsonicStructuredLyrics {
            SubsonicStructuredLyrics(
                lang: lang,
                synced: synced,
                offset: offset,
                displayArtist: displayArtist,
                displayTitle: displayTitle,
                lines: lines.map { .init(start: $0.start, value: $0.value) }
            )
        }

        enum CodingKeys: String, CodingKey {
            case lang
            case synced
            case offset
            case displayArtist
            case displayTitle
            case lines
            case line
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lang = try values.decodeIfPresent(String.self, forKey: .lang) ?? "xxx"
            synced = try values.decode(Bool.self, forKey: .synced)
            offset = try values.decodeIfPresent(Int.self, forKey: .offset) ?? 0
            displayArtist = try values.decodeIfPresent(String.self, forKey: .displayArtist)
            displayTitle = try values.decodeIfPresent(String.self, forKey: .displayTitle)
            lines =
                try values.decodeIfPresent([Line].self, forKey: .lines)
                ?? values.decodeIfPresent([Line].self, forKey: .line)
                ?? []
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(lang, forKey: .lang)
            try values.encode(synced, forKey: .synced)
            try values.encode(offset, forKey: .offset)
            try values.encodeIfPresent(displayArtist, forKey: .displayArtist)
            try values.encodeIfPresent(displayTitle, forKey: .displayTitle)
            try values.encode(lines, forKey: .lines)
        }
    }

    fileprivate struct StoredSelection: Codable {
        var key: String?
        var serverId: String?
        var title: String?
        var artist: String?
        var lyrics: String?
        var romaji: String?
        var disabled: Bool
        var offset: Double
        var changedAt: TimeInterval

        init(selection: CustomLyricsSelection, changedAt: TimeInterval) {
            key = selection.key
            serverId = selection.serverId
            title = selection.title
            artist = selection.artist
            lyrics = selection.lyrics
            romaji = selection.romaji
            disabled = selection.disabled
            offset = selection.offset
            self.changedAt = changedAt
        }

        var selection: CustomLyricsSelection {
            CustomLyricsSelection(
                key: key,
                serverId: serverId,
                title: title,
                artist: artist,
                lyrics: lyrics,
                romaji: romaji,
                disabled: disabled,
                offset: offset
            )
        }

        enum CodingKeys: String, CodingKey {
            case key
            case serverId
            case title
            case artist
            case lyrics
            case romaji
            case disabled
            case offset
            case changedAt = "_changedAt"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            key = try values.decodeIfPresent(String.self, forKey: .key)
            serverId = try values.decodeIfPresent(String.self, forKey: .serverId)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            artist = try values.decodeIfPresent(String.self, forKey: .artist)
            lyrics = try values.decodeIfPresent(String.self, forKey: .lyrics)
            romaji = try values.decodeIfPresent(String.self, forKey: .romaji)
            disabled = try values.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            offset = try values.decodeIfPresent(Double.self, forKey: .offset) ?? 0
            changedAt = try values.decodeIfPresent(TimeInterval.self, forKey: .changedAt) ?? 0
        }
    }
}

extension String {
    fileprivate var trimmedNonempty: String? {
        let value = replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
