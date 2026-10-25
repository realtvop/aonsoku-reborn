import Foundation
import Observation

// MARK: - Pinned

/// An album or playlist pinned to Home (web `pinned_home_store`).
public struct PinnedItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case album
        case playlist
    }

    public var itemId: String
    public var kind: Kind

    public init(itemId: String, kind: Kind) {
        self.itemId = itemId
        self.kind = kind
    }

    /// Unique across kinds.
    public var id: String { "\(kind.rawValue):\(itemId)" }

    private enum CodingKeys: String, CodingKey {
        case itemId = "id"
        case kind = "type"
    }
}

/// A pinned item resolved for display.
public enum PinnedContent: Identifiable, Hashable, Sendable {
    case album(Album)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case let .album(album): "album:\(album.id)"
        case let .playlist(playlist): "playlist:\(playlist.id)"
        }
    }
}

/// Pins on Home, persisted under `pinned.v1` as `[PinnedItem]`, newest first.
@MainActor
@Observable
public final class PinnedHomeStore {
    public private(set) var items: [PinnedItem] = []
    /// Pins that still exist, sorted by last played (newest first), then
    /// name, as on the web Home page.
    public private(set) var resolved: [PinnedContent] = []

    @ObservationIgnored public let preferences: PreferencesService
    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored private var resolveGeneration = 0

    public init(preferences: PreferencesService, repository: LibraryRepository) {
        self.preferences = preferences
        self.repository = repository
    }

    /// Reads the stored pins. Call once at start.
    public func load() {
        let stored = preferences.getJSON("pinned.v1", as: [PinnedItem].self) ?? []
        var seen = Set<String>()
        items = stored.filter { seen.insert($0.id).inserted }
    }

    public func reset() {
        resolveGeneration += 1
        items = []
        resolved = []
    }

    public func isPinned(_ itemId: String, kind: PinnedItem.Kind) -> Bool {
        items.contains { $0.itemId == itemId && $0.kind == kind }
    }

    /// Adds the pin at the front. Pinning again has no effect.
    public func pin(_ itemId: String, kind: PinnedItem.Kind) {
        guard !isPinned(itemId, kind: kind) else { return }
        items.insert(PinnedItem(itemId: itemId, kind: kind), at: 0)
        persist()
        Task { [weak self] in await self?.resolve() }
    }

    public func unpin(_ itemId: String, kind: PinnedItem.Kind) {
        let id = "\(kind.rawValue):\(itemId)"
        items.removeAll { $0.id == id }
        resolved.removeAll { $0.id == id }
        persist()
    }

    public func toggle(_ itemId: String, kind: PinnedItem.Kind) {
        if isPinned(itemId, kind: kind) {
            unpin(itemId, kind: kind)
        } else {
            pin(itemId, kind: kind)
        }
    }

    /// Refreshes `resolved` from the library.
    public func resolve() async {
        resolveGeneration += 1
        let generation = resolveGeneration
        let requestedItems = items
        var values: [(content: PinnedContent, activity: Date)] = []

        for item in requestedItems {
            switch item.kind {
            case .album:
                var detail = await repository.cachedAlbum(id: item.itemId)
                if detail == nil, repository.connectivity.isOnline {
                    detail = try? await repository.album(id: item.itemId)
                }
                if let detail {
                    let activity = ([detail.album.played] + detail.songs.map(\.played))
                        .compactMap { $0 }
                        .max() ?? .distantPast
                    values.append((.album(detail.album), activity))
                }
            case .playlist:
                var detail = await repository.cachedPlaylist(id: item.itemId)
                if detail == nil, repository.connectivity.isOnline {
                    detail = try? await repository.playlist(id: item.itemId)
                }
                if let detail {
                    let activity = detail.songs.compactMap(\.played).max()
                        ?? detail.playlist.changed
                        ?? detail.playlist.created
                        ?? .distantPast
                    values.append((.playlist(detail.playlist), activity))
                }
            }
        }

        guard generation == resolveGeneration else { return }
        let currentIds = Set(items.map(\.id))
        resolved = values
            .filter { currentIds.contains($0.content.id) }
            .sorted {
                if $0.activity != $1.activity { return $0.activity > $1.activity }
                return Self.name($0.content).localizedCaseInsensitiveCompare(
                    Self.name($1.content)
                ) == .orderedAscending
            }
            .map(\.content)
    }

    private func persist() {
        try? preferences.setJSON(items, for: "pinned.v1")
    }

    private static func name(_ content: PinnedContent) -> String {
        switch content {
        case let .album(album): album.name
        case let .playlist(playlist): playlist.name
        }
    }
}

// MARK: - Favorites

/// What a favorite refers to.
public enum FavoriteKind: String, Hashable, Sendable {
    case song
    case album
    case artist
}

/// Starred songs, albums and artists. Toggles apply immediately, are sent to
/// the server, and roll back with an error toast when the server rejects
/// them. The local library is updated so offline lists stay consistent.
@MainActor
@Observable
public final class FavoritesStore {
    public private(set) var songIds: Set<String> = []
    public private(set) var albumIds: Set<String> = []
    public private(set) var artistIds: Set<String> = []
    /// Increments after every change, for lists that should reload.
    public private(set) var revision = 0

    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public weak var toasts: ToastCenter?
    @ObservationIgnored private var requests: [FavoriteRequestKey: FavoriteRequest] = [:]
    @ObservationIgnored private var requestTasks: [FavoriteRequestKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingMutations: Set<FavoriteRequestKey> = []
    @ObservationIgnored private var loadGeneration: UInt64 = 0

    public init(api: any SubsonicAPI, library: LibraryService, toasts: ToastCenter? = nil) {
        self.api = api
        self.library = library
        self.toasts = toasts
    }

    /// Loads starred ids from the local library, then from `getStarred2`
    /// when online.
    public func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if let local = try? library.starredIds() {
            replace(
                songs: local.songIds,
                albums: local.albumIds,
                artists: local.artistIds,
                authoritative: false
            )
        }
        do {
            let remote = try await api.starred()
            guard generation == loadGeneration else { return }
            replace(
                songs: Set(remote.songs.map(\.id)),
                albums: Set(remote.albums.map(\.id)),
                artists: Set(remote.artists.map(\.id)),
                authoritative: true
            )
        } catch {
            // The local snapshot remains useful while offline.
        }
    }

    public func reset() {
        loadGeneration &+= 1
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        requests.removeAll()
        pendingMutations.removeAll()
        songIds = []
        albumIds = []
        artistIds = []
        revision += 1
    }

    public func isFavorite(_ kind: FavoriteKind, id: String) -> Bool {
        switch kind {
        case .song: songIds.contains(id)
        case .album: albumIds.contains(id)
        case .artist: artistIds.contains(id)
        }
    }

    public func toggle(_ kind: FavoriteKind, id: String) async {
        await setFavorite(kind, id: id, isFavorite: !isFavorite(kind, id: id))
    }

    public func setFavorite(_ kind: FavoriteKind, id: String, isFavorite: Bool) async {
        let key = FavoriteRequestKey(kind: kind, id: id)
        if var request = requests[key] {
            request.wanted = isFavorite
            requests[key] = request
            apply(kind, id: id, isFavorite: isFavorite)
            await requestTasks[key]?.value
            return
        }
        let confirmed = self.isFavorite(kind, id: id)
        guard confirmed != isFavorite else { return }

        requests[key] = FavoriteRequest(confirmed: confirmed, wanted: isFavorite)
        apply(kind, id: id, isFavorite: isFavorite)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainRequest(key)
        }
        requestTasks[key] = task
        await task.value
    }

    /// Stars or unstars several songs at once.
    public func setFavorite(songIds: [String], isFavorite: Bool) async {
        var seen = Set<String>()
        let ids = songIds.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }

        if ids.contains(where: {
            requests[FavoriteRequestKey(kind: .song, id: $0)] != nil
        }) {
            for id in ids {
                await setFavorite(.song, id: id, isFavorite: isFavorite)
            }
            return
        }

        let confirmed = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, self.isFavorite(.song, id: $0))
        })
        let changedIds = ids.filter { confirmed[$0] != isFavorite }
        guard !changedIds.isEmpty else { return }
        apply(.song, ids: changedIds, isFavorite: isFavorite)
        do {
            let target = StarTarget(songIds: changedIds)
            if isFavorite {
                try await api.star(target)
            } else {
                try await api.unstar(target)
            }
        } catch {
            let starred = Set(changedIds.filter { confirmed[$0] == true })
            let unstarred = Set(changedIds).subtracting(starred)
            apply(.song, ids: Array(starred), isFavorite: true)
            apply(.song, ids: Array(unstarred), isFavorite: false)
            toasts?.show(error: error)
            return
        }
        do {
            try library.setStarred(songIds: changedIds, starred: isFavorite)
        } catch {
            toasts?.show(error: error)
        }
    }

    private func drainRequest(_ key: FavoriteRequestKey) async {
        while let request = requests[key] {
            let wanted = request.wanted
            do {
                let target = target(for: key)
                if wanted {
                    try await api.star(target)
                } else {
                    try await api.unstar(target)
                }
                guard var current = requests[key] else { break }
                current.confirmed = wanted
                requests[key] = current
                do {
                    try library.setStarred(
                        songIds: key.kind == .song ? [key.id] : [],
                        albumIds: key.kind == .album ? [key.id] : [],
                        artistIds: key.kind == .artist ? [key.id] : [],
                        starred: wanted
                    )
                } catch {
                    toasts?.show(error: error)
                }
                if current.wanted == wanted {
                    requests[key] = nil
                    break
                }
            } catch {
                guard let current = requests[key] else { break }
                apply(key.kind, id: key.id, isFavorite: current.confirmed)
                toasts?.show(error: error)
                if current.wanted == wanted {
                    requests[key] = nil
                    break
                }
                apply(key.kind, id: key.id, isFavorite: current.wanted)
            }
        }
        requestTasks[key] = nil
    }

    private func target(for key: FavoriteRequestKey) -> StarTarget {
        switch key.kind {
        case .song: .song(key.id)
        case .album: .album(key.id)
        case .artist: .artist(key.id)
        }
    }

    private func replace(
        songs: Set<String>,
        albums: Set<String>,
        artists: Set<String>,
        authoritative: Bool
    ) {
        var songs = songs
        var albums = albums
        var artists = artists
        var protected = pendingMutations
        protected.formUnion(requests.keys)
        if authoritative {
            for key in pendingMutations where requests[key] == nil {
                let remote = switch key.kind {
                case .song: songs.contains(key.id)
                case .album: albums.contains(key.id)
                case .artist: artists.contains(key.id)
                }
                if remote == isFavorite(key.kind, id: key.id) {
                    pendingMutations.remove(key)
                    protected.remove(key)
                }
            }
        }
        for key in protected {
            let wanted = requests[key]?.wanted ?? isFavorite(key.kind, id: key.id)
            switch key.kind {
            case .song:
                if wanted { songs.insert(key.id) } else { songs.remove(key.id) }
            case .album:
                if wanted { albums.insert(key.id) } else { albums.remove(key.id) }
            case .artist:
                if wanted { artists.insert(key.id) } else { artists.remove(key.id) }
            }
        }
        guard songIds != songs || albumIds != albums || artistIds != artists else {
            return
        }
        songIds = songs
        albumIds = albums
        artistIds = artists
        revision += 1
    }

    private func apply(_ kind: FavoriteKind, id: String, isFavorite: Bool) {
        apply(kind, ids: [id], isFavorite: isFavorite)
    }

    private func apply(_ kind: FavoriteKind, ids: [String], isFavorite: Bool) {
        guard !ids.isEmpty else { return }
        let before: Set<String>
        switch kind {
        case .song: before = songIds
        case .album: before = albumIds
        case .artist: before = artistIds
        }
        var after = before
        if isFavorite {
            after.formUnion(ids)
        } else {
            after.subtract(ids)
        }
        guard before != after else { return }
        for id in ids {
            pendingMutations.insert(FavoriteRequestKey(kind: kind, id: id))
        }
        switch kind {
        case .song: songIds = after
        case .album: albumIds = after
        case .artist: artistIds = after
        }
        revision += 1
    }
}

private struct FavoriteRequestKey: Hashable {
    var kind: FavoriteKind
    var id: String
}

private struct FavoriteRequest {
    var confirmed: Bool
    var wanted: Bool
}

// MARK: - Playlists

/// The user's playlists and playlist editing.
@MainActor
@Observable
public final class PlaylistsStore {
    public private(set) var playlists: [Playlist] = []
    public private(set) var phase: LoadPhase = .idle
    /// Increments after an edit so open playlist screens reload.
    public private(set) var revision = 0

    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored private var loadGeneration: UInt64 = 0

    public init(repository: LibraryRepository, api: any SubsonicAPI) {
        self.repository = repository
        self.api = api
    }

    public func loadIfNeeded() async {
        guard phase == .idle else { return }
        await reload()
    }

    public func reload() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if playlists.isEmpty { phase = .loading }
        do {
            let values = try await repository.playlists()
            guard generation == loadGeneration else { return }
            playlists = values
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    public func reset() {
        loadGeneration &+= 1
        playlists = []
        phase = .idle
        revision += 1
    }

    /// Creates a playlist, optionally with songs, and returns it.
    @discardableResult
    public func create(
        name: String,
        comment: String? = nil,
        isPublic: Bool = false,
        songIds: [String] = []
    ) async throws -> Playlist? {
        var created = try await api.createPlaylist(name: name, songIds: songIds)?.playlist
        if created == nil {
            created = try await api.playlists()
                .filter { $0.name == name }
                .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
                .first
        }
        guard var created else {
            await reload()
            revision += 1
            return nil
        }

        if !(comment ?? "").isEmpty || isPublic {
            try await api.updatePlaylist(
                id: created.id,
                changes: PlaylistChanges(comment: comment, isPublic: isPublic)
            )
            created.comment = comment
            created.isPublic = isPublic
        }
        try? await repository.library.refreshPlaylist(id: created.id)
        await reload()
        revision += 1
        return created
    }

    public func update(
        _ playlistId: String,
        name: String,
        comment: String?,
        isPublic: Bool
    ) async throws {
        try await api.updatePlaylist(
            id: playlistId,
            changes: PlaylistChanges(name: name, comment: comment, isPublic: isPublic)
        )
        try await repository.library.refreshPlaylist(id: playlistId)
        await reload()
        revision += 1
    }

    public func delete(_ playlistId: String) async throws {
        try await api.deletePlaylist(id: playlistId)
        try repository.library.removePlaylist(id: playlistId)
        playlists.removeAll { $0.id == playlistId }
        revision += 1
    }

    /// Appends songs. Returns the ids that were already in the playlist and
    /// were skipped.
    @discardableResult
    public func add(songIds: [String], to playlistId: String) async throws -> [String] {
        let detail = try await repository.playlist(id: playlistId)
        var seen = Set(detail.songs.map(\.id))
        var newIds: [String] = []
        var skipped: [String] = []
        for id in songIds {
            if seen.insert(id).inserted {
                newIds.append(id)
            } else {
                skipped.append(id)
            }
        }
        guard !newIds.isEmpty else { return skipped }
        try await api.updatePlaylist(
            id: playlistId,
            changes: PlaylistChanges(songIdsToAdd: newIds)
        )
        try await repository.library.refreshPlaylist(id: playlistId)
        revision += 1
        return skipped
    }

    /// Removes the entries at `indexes` (positions in the playlist).
    public func remove(indexes: [Int], from playlistId: String) async throws {
        let values = Array(Set(indexes)).sorted()
        guard !values.isEmpty else { return }
        try await api.updatePlaylist(
            id: playlistId,
            changes: PlaylistChanges(songIndexesToRemove: values)
        )
        try await repository.library.refreshPlaylist(id: playlistId)
        await reload()
        revision += 1
    }
}

// MARK: - Radio

/// Internet radio stations stored on the server.
@MainActor
@Observable
public final class RadioStore {
    public private(set) var stations: [RadioStation] = []
    public private(set) var phase: LoadPhase = .idle

    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored private var loadGeneration: UInt64 = 0

    public init(api: any SubsonicAPI) {
        self.api = api
    }

    public func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if stations.isEmpty { phase = .loading }
        do {
            let values = try await api.radioStations()
            guard generation == loadGeneration else { return }
            stations = values
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    public func reset() {
        loadGeneration &+= 1
        stations = []
        phase = .idle
    }

    public func create(name: String, streamUrl: String, homePageUrl: String?) async throws {
        try await api.createRadioStation(
            name: name,
            streamUrl: streamUrl,
            homePageUrl: homePageUrl
        )
        await load()
    }

    public func update(_ station: RadioStation) async throws {
        try await api.updateRadioStation(station)
        await load()
    }

    public func delete(_ stationId: String) async throws {
        try await api.deleteRadioStation(id: stationId)
        await load()
    }
}

// MARK: - Listening history

/// Songs the user listened to, newest first (web `player_history`), stored
/// in the native play history so it survives reinstalls of the WebView.
///
/// A song is recorded when playback moves to another song after at least
/// ten seconds of accumulated local playback. Nothing is recorded while
/// controlling another device.
@MainActor
@Observable
public final class ListeningHistoryStore {
    public private(set) var songs: [Song] = []

    @ObservationIgnored public let preferences: PreferencesService
    /// Entries kept; from `HistorySettings.maxSize`.
    @ObservationIgnored public var maxSize = HistorySettings().maxSize
    @ObservationIgnored private var trackedSong: Song?
    @ObservationIgnored private var accumulatedPlayback: TimeInterval = 0
    @ObservationIgnored private var playingSince: Date?

    public init(preferences: PreferencesService) {
        self.preferences = preferences
    }

    public func load() {
        let values = (try? preferences.getPlayHistory(limit: max(0, maxSize))) ?? []
        songs = values.compactMap { value in
            guard let data = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                return nil
            }
            return SubsonicJSON.song(dictionary)
        }
    }

    /// Adds `song` at the front and trims to `maxSize`.
    public func record(_ song: Song) {
        let limit = max(0, maxSize)
        if songs.first?.id != song.id {
            songs.insert(song, at: 0)
        }
        if songs.count > limit { songs = Array(songs.prefix(limit)) }
        save()
    }

    public func remove(at index: Int) {
        guard songs.indices.contains(index) else { return }
        songs.remove(at: index)
        save()
    }

    public func clear() {
        songs = []
        try? preferences.clearPlayHistory()
        resetTracking()
    }

    public func reset() {
        songs = []
        resetTracking()
    }

    /// Feeds playback changes. Call on every song, play state or target
    /// change; `now` is injectable for tests.
    public func trackPlayback(
        song: Song?,
        isPlaying: Bool,
        isRemote: Bool,
        now: Date = Date()
    ) {
        if trackedSong?.id != song?.id {
            finishInterval(at: now)
            if let trackedSong, accumulatedPlayback >= 10 {
                record(trackedSong)
            }
            trackedSong = nil
            accumulatedPlayback = 0
            playingSince = nil
        }

        guard let song, isPlaying, !isRemote else {
            finishInterval(at: now)
            return
        }
        if trackedSong == nil { trackedSong = song }
        if playingSince == nil { playingSince = now }
    }

    private func finishInterval(at now: Date) {
        guard let playingSince else { return }
        accumulatedPlayback += max(0, now.timeIntervalSince(playingSince))
        self.playingSince = nil
    }

    private func resetTracking() {
        trackedSong = nil
        accumulatedPlayback = 0
        playingSince = nil
    }

    private func save() {
        do {
            try preferences.clearPlayHistory()
            for song in songs.reversed() {
                try preferences.addToPlayHistory(
                    songJSON: try song.playHistoryJSON(),
                    maxSize: max(0, maxSize)
                )
            }
        } catch {
            NativeLogger.shared.error(
                "failed to save listening history: \(error)",
                source: "ListeningHistory"
            )
        }
    }
}
