import Foundation
import Observation

/// Offline downloads and the cache manager (web `src/service/cache/*`).
///
/// Every cached file has a row in the native `cacheMeta` index with its
/// source: `explicit` downloads are never evicted, `smart` entries follow the
/// smart download rules, and `lru` entries come from streaming and are
/// evicted oldest first over the quota. Albums and playlists get marker
/// rows so they show as downloaded.
@MainActor
@Observable
public final class DownloadsStore {
    public private(set) var usage = CacheUsage()
    public private(set) var activeDownloads = ActiveDownloadsSummary()
    /// Increments when the index changes, for screens listing downloads.
    public private(set) var revision = 0

    @ObservationIgnored public let audio: AudioService
    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public weak var favorites: FavoritesStore?
    @ObservationIgnored public weak var toasts: ToastCenter?
    @ObservationIgnored public var onAssetsCleared: (() -> Void)?

    @ObservationIgnored private var rows: [String: CacheMetaRecord] = [:]
    @ObservationIgnored private var progress: [String: DownloadProgress] = [:]
    @ObservationIgnored private var progressOrder: [String] = []
    @ObservationIgnored private var pending: [String: PendingDownload] = [:]
    @ObservationIgnored private var collectionSongIds: [String: [String]] = [:]
    @ObservationIgnored private var audioObservation: UUID?
    @ObservationIgnored private var didToastBatchFailure = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let commands: DownloadCommands

    public init(
        audio: AudioService,
        library: LibraryService,
        repository: LibraryRepository,
        settings: SettingsStore
    ) {
        self.audio = audio
        self.library = library
        self.repository = repository
        self.settings = settings
        now = { Date() }
        commands = DownloadCommands(audio: audio)
    }

    init(
        audio: AudioService,
        library: LibraryService,
        repository: LibraryRepository,
        settings: SettingsStore,
        now: @escaping @Sendable () -> Date,
        commands: DownloadCommands? = nil
    ) {
        self.audio = audio
        self.library = library
        self.repository = repository
        self.settings = settings
        self.now = now
        self.commands = commands ?? DownloadCommands(audio: audio)
    }

    deinit {
        if let audioObservation { audio.unsubscribe(audioObservation) }
    }

    /// Subscribes to download and stream-cache events and loads the index.
    public func start() {
        guard !started else { return }
        started = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        reloadIndex()
        audioObservation = audio.subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleAudioEvent(event)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.hydrateCollectionSongs(generation: generation)
            guard generation == self.lifecycleGeneration else { return }
            await self.refreshUsage()
        }
    }

    public func stop() {
        lifecycleGeneration &+= 1
        cancelAll()
        if let audioObservation { audio.unsubscribe(audioObservation) }
        audioObservation = nil
        started = false
        rows = [:]
        collectionSongIds = [:]
        usage = CacheUsage()
        revision += 1
    }

    func reloadAfterLibrarySync() {
        reloadIndex()
    }

    // MARK: State

    public func state(ofSong id: String) -> SongCacheState {
        if let progress = progress[id] {
            return .downloading(progress: progress.fraction)
        }
        guard let row = rows[Self.audioKey(id)], fileExists(for: row) else {
            return .notCached
        }
        return .cached(
            source: CacheSource(stored: row.source),
            removedFromServer: row.removedFromServer ?? false
        )
    }

    public func state(ofAlbum id: String) -> CollectionCacheState {
        collectionState(key: Self.albumKey(id))
    }

    public func state(ofPlaylist id: String) -> CollectionCacheState {
        collectionState(key: Self.playlistKey(id))
    }

    // MARK: Downloads

    public func download(songs: [Song]) async {
        await enqueue(songs: songs, source: .explicit, triggers: [])
    }

    public func download(albumId: String) async {
        do {
            let detail = try await repository.album(id: albumId)
            let key = Self.albumKey(albumId)
            let songIds = detail.songs.map(\.id)
            collectionSongIds[key] = songIds
            upsert(marker(id: albumId, type: .album, songIds: songIds))
            await enqueue(songs: detail.songs, source: .explicit, triggers: [])
        } catch {
            toasts?.show(error: error)
        }
    }

    public func download(playlistId: String) async {
        do {
            let detail = try await repository.playlist(id: playlistId)
            let key = Self.playlistKey(playlistId)
            let songIds = detail.songs.map(\.id)
            collectionSongIds[key] = songIds
            upsert(marker(id: playlistId, type: .playlist, songIds: songIds))
            await enqueue(songs: detail.songs, source: .explicit, triggers: [])
        } catch {
            toasts?.show(error: error)
        }
    }

    public func download(artistId: String) async {
        do {
            let detail = try await repository.artist(id: artistId)
            var songs: [Song] = []
            var seen = Set<String>()
            for album in detail.albums {
                let albumDetail = try await repository.album(id: album.id)
                songs.append(contentsOf: albumDetail.songs.filter {
                    seen.insert($0.id).inserted
                })
            }
            await enqueue(songs: songs, source: .explicit, triggers: [])
        } catch {
            toasts?.show(error: error)
        }
    }

    /// Removes explicit downloads; songs kept by another source stay.
    public func remove(songIds: [String]) async {
        let keptByCollections = explicitCollectionSongIds()
        for songId in Set(songIds) {
            await removeExplicitSong(songId, keptByCollections: keptByCollections)
        }
        await refreshUsage()
    }

    public func remove(albumId: String) async {
        await removeCollection(key: Self.albumKey(albumId))
    }

    public func remove(playlistId: String) async {
        await removeCollection(key: Self.playlistKey(playlistId))
    }

    public func cancelAll() {
        commands.cancel(nil)
        progress.removeAll()
        progressOrder.removeAll()
        pending.removeAll()
        didToastBatchFailure = false
        updateActiveDownloads()
        revision += 1
    }

    // MARK: Offline library

    public func downloadedAlbums() async -> [Album] {
        var values: [Album] = []
        for row in rows.values where row.type == CachedItemType.album.rawValue {
            if let album = await repository.cachedAlbum(id: row.id)?.album {
                values.append(album)
            }
        }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func downloadedPlaylists() async -> [Playlist] {
        var values: [Playlist] = []
        for row in rows.values where row.type == CachedItemType.playlist.rawValue {
            if let playlist = await repository.cachedPlaylist(id: row.id)?.playlist {
                values.append(playlist)
            }
        }
        return values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func downloadedSongs() async -> [Song] {
        let ids = rows.values
            .filter {
                $0.type == CachedItemType.audio.rawValue
                    && $0.source == CacheSource.explicit.rawValue
            }
            .filter(fileExists)
            .map(\.id)
        let values = (try? await repository.songs(ids: ids)) ?? []
        return values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Cache manager

    public func items(filter: CacheFilter) async -> [CachedItem] {
        var values: [CachedItem] = []
        for row in rows.values {
            guard let type = CachedItemType(rawValue: row.type) else { continue }
            let display = displayName(for: row, type: type)
            let item = CachedItem(
                key: row.key,
                itemId: row.id,
                type: type,
                source: CacheSource(stored: row.source),
                name: display.name,
                subtitle: display.subtitle,
                sizeBytes: Int64(row.sizeBytes),
                cachedAt: Self.date(milliseconds: row.cachedAt),
                lastAccessedAt: Self.date(milliseconds: row.lastAccessedAt),
                coverSize: row.coverSize,
                removedFromServer: row.removedFromServer ?? false
            )
            if filter.matches(item) { values.append(item) }
        }
        return values.sorted { $0.cachedAt > $1.cachedAt }
    }

    public func delete(_ items: [CachedItem]) async {
        for item in items {
            switch item.type {
            case .album, .playlist:
                await removeCollection(key: item.key)
            case .audio, .cover:
                await deleteRow(key: item.key, deleteFile: true)
            }
        }
        await refreshUsage()
    }

    /// Deletes audio and collection markers of one source.
    public func clear(source: CacheSource) async {
        if source == .explicit {
            let markerKeys = rows.values.filter {
                $0.source == source.rawValue
                    && ($0.type == CachedItemType.album.rawValue
                        || $0.type == CachedItemType.playlist.rawValue)
            }.map(\.key)
            removeRows(keys: markerKeys)
            let kept = explicitCollectionSongIds()
            let songIds = Set(rows.values.filter {
                $0.source == source.rawValue && $0.type == CachedItemType.audio.rawValue
            }.map(\.id)).union(pending.compactMap { id, request in
                request.source == .explicit ? id : nil
            })
            for id in songIds {
                await removeExplicitSong(id, keptByCollections: kept)
            }
        } else {
            if source == .smart {
                let smartPending = pending.compactMap { id, request in
                    request.source == .smart ? id : nil
                }
                for id in smartPending { cancelPending(id) }
                for (id, request) in pending where
                    request.source == .explicit && !request.triggers.isEmpty
                {
                    pending[id]?.triggers = []
                }
            }
            let values = rows.values.filter {
                $0.source == source.rawValue && $0.type != CachedItemType.cover.rawValue
            }
            for row in values {
                await deleteRow(
                    key: row.key,
                    deleteFile: row.type == CachedItemType.audio.rawValue
                )
            }
            if source == .smart {
                for var row in rows.values where
                    row.type == CachedItemType.audio.rawValue
                        && row.source == CacheSource.explicit.rawValue
                        && !Self.triggers(from: row).isEmpty
                {
                    row.triggersJson = nil
                    upsert(row)
                }
            }
        }
        await refreshUsage()
    }

    /// Deletes all cover art.
    public func clearAssets() async {
        _ = try? library.clearCovers()
        onAssetsCleared?()
        let keys = rows.values
            .filter { $0.type == CachedItemType.cover.rawValue }
            .map(\.key)
        removeRows(keys: keys)
        await refreshUsage()
    }

    public func refreshUsage() async {
        var next = CacheUsage()
        for row in rows.values {
            let size = Int64(max(0, row.sizeBytes))
            if row.type == CachedItemType.cover.rawValue {
                next.assets.sizeBytes += size
                next.assets.count += 1
            } else if row.type == CachedItemType.audio.rawValue {
                switch CacheSource(stored: row.source) {
                case .explicit:
                    next.explicit.sizeBytes += size
                    next.explicit.count += 1
                case .smart:
                    next.smart.sizeBytes += size
                    next.smart.count += 1
                case .lru:
                    next.lru.sizeBytes += size
                    next.lru.count += 1
                }
            }
        }
        usage = next
    }

    /// Applies the smart rules: downloads favorite songs and songs of
    /// favorite playlists, and removes smart entries that no longer match.
    /// Skipped on metered networks.
    public func applySmartRules() async {
        let rules = settings.settings.cache.smartRules
        guard !repository.connectivity.isMetered else { return }

        var targets: [String: Set<String>] = [:]
        if rules.enabled, rules.favoriteSongs {
            let ids = favorites?.songIds ?? (try? library.starredIds().songIds) ?? []
            for id in ids { targets[id, default: []].insert("favorite") }
        }
        if rules.enabled, rules.favoritePlaylists {
            let playlists = (try? library.playlists(limit: Int.max).items) ?? []
            var resolutionFailed = false
            for playlist in playlists where playlist.starred != nil {
                let detail: PlaylistDetail
                if let cached = await repository.cachedPlaylist(id: playlist.id) {
                    detail = cached
                } else {
                    do {
                        detail = try await repository.playlist(id: playlist.id)
                    } catch {
                        resolutionFailed = true
                        continue
                    }
                }
                for song in detail.songs {
                    targets[song.id, default: []].insert("playlist")
                }
            }
            if resolutionFailed {
                for row in rows.values where row.type == CachedItemType.audio.rawValue {
                    let triggers = Self.triggers(from: row)
                    guard triggers.contains("playlist")
                            || (row.source == CacheSource.smart.rawValue && triggers.isEmpty)
                    else {
                        continue
                    }
                    targets[row.id, default: []].insert("playlist")
                }
                for (id, request) in pending {
                    guard request.triggers.contains("playlist")
                            || (request.source == .smart && request.triggers.isEmpty)
                    else {
                        continue
                    }
                    targets[id, default: []].insert("playlist")
                }
            }
        }
        guard !Task.isCancelled else { return }

        for id in Array(pending.keys) where targets[id] == nil {
            guard let request = pending[id] else { continue }
            if request.source == .smart {
                cancelPending(id)
            } else if request.source == .explicit, !request.triggers.isEmpty {
                pending[id]?.triggers = []
            }
        }

        for var row in rows.values where row.type == CachedItemType.audio.rawValue {
            guard !Task.isCancelled else { return }
            guard targets[row.id] == nil else { continue }
            if row.source == CacheSource.smart.rawValue {
                await deleteRow(key: row.key, deleteFile: true)
            } else if row.source == CacheSource.explicit.rawValue,
                !Self.triggers(from: row).isEmpty
            {
                row.triggersJson = nil
                upsert(row)
            }
        }

        let songs = (try? await repository.songs(ids: Array(targets.keys))) ?? []
        guard !Task.isCancelled else { return }
        for song in songs {
            guard !Task.isCancelled else { return }
            await enqueue(
                songs: [song],
                source: .smart,
                triggers: Array(targets[song.id] ?? []).sorted()
            )
        }
        await refreshUsage()
    }

    /// Deletes least recently used entries over the quotas.
    public func enforceQuotas() async {
        let cache = settings.settings.cache
        await evict(
            rows.values.filter {
                $0.type == CachedItemType.audio.rawValue
                    && $0.source == CacheSource.lru.rawValue
            },
            quota: cache.lruQuota
        )
        await evict(
            rows.values.filter { $0.type == CachedItemType.cover.rawValue },
            quota: cache.assetsQuota
        )
        await refreshUsage()
    }

    // MARK: Audio events

    func handleAudioEvent(_ event: AudioServiceEvent) {
        switch event {
        case let .downloadProgress(songId, requestId, loaded, total):
            guard let requestId,
                  pending[songId]?.requestId == requestId else { return }
            if progress[songId] == nil { progressOrder.append(songId) }
            progress[songId] = DownloadProgress(loaded: loaded, total: total)
            updateActiveDownloads()
        case let .downloadCompleted(songId, requestId, file):
            guard let requestId,
                  let request = pending[songId],
                  request.requestId == requestId else {
                if pending[songId] == nil,
                   rows[Self.audioKey(songId)] == nil {
                    _ = try? audio.deleteAudioFile(songId: songId)
                }
                return
            }
            pending.removeValue(forKey: songId)
            progress.removeValue(forKey: songId)
            progressOrder.removeAll { $0 == songId }
            recordAudio(file, source: request.source, triggers: request.triggers)
            updateActiveDownloads()
            Task { [weak self] in
                await self?.refreshUsage()
                await self?.enforceQuotas()
            }
        case let .downloadFailed(songId, requestId, message):
            guard let requestId,
                  pending[songId]?.requestId == requestId else {
                return
            }
            pending.removeValue(forKey: songId)
            progress.removeValue(forKey: songId)
            progressOrder.removeAll { $0 == songId }
            updateActiveDownloads()
            if !didToastBatchFailure {
                didToastBatchFailure = true
                toasts?.show(.text(message), style: .error)
            }
        case let .streamCacheCompleted(songId, file):
            guard rows[Self.audioKey(songId)] == nil else { return }
            recordAudio(file, source: .lru, triggers: [])
            Task { [weak self] in await self?.enforceQuotas() }
        default:
            break
        }
    }

    // MARK: Index

    private func reloadIndex() {
        let values = (try? library.cacheMetadata()) ?? []
        rows = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0) })
        collectionSongIds.removeAll()
        for row in values {
            if row.type == CachedItemType.album.rawValue
                || row.type == CachedItemType.playlist.rawValue,
                row.triggersJson != nil
            {
                collectionSongIds[row.key] = Self.triggers(from: row)
            } else if row.type == CachedItemType.album.rawValue,
                let detail = try? library.album(id: row.id)
            {
                collectionSongIds[row.key] = detail.songs.map(\.id)
            } else if row.type == CachedItemType.playlist.rawValue,
                let detail = try? library.playlist(id: row.id)?.mediaValue
            {
                collectionSongIds[row.key] = detail.songs.map(\.id)
            }
        }
        revision += 1
    }

    private func upsert(_ row: CacheMetaRecord) {
        do {
            try library.upsertCacheMetadata(row)
            rows[row.key] = row
            revision += 1
        } catch {
            NativeLogger.shared.error(
                "failed to persist cache metadata: \(error)",
                source: "DownloadsStore"
            )
        }
    }

    private func removeRows(keys: [String]) {
        guard !keys.isEmpty else { return }
        do {
            try library.deleteCacheMetadata(keys: keys)
            for key in keys {
                rows[key] = nil
                collectionSongIds[key] = nil
            }
            revision += 1
        } catch {
            NativeLogger.shared.error(
                "failed to delete cache metadata: \(error)",
                source: "DownloadsStore"
            )
        }
    }

    private func marker(
        id: String,
        type: CachedItemType,
        songIds: [String]
    ) -> CacheMetaRecord {
        let timestamp = nowMilliseconds
        return CacheMetaRecord(
            key: "\(type.rawValue):\(id)",
            id: id,
            type: type.rawValue,
            source: CacheSource.explicit.rawValue,
            triggersJson: Self.encodeCollectionSongIds(songIds),
            coverSize: nil,
            sizeBytes: 0,
            cachedAt: rows["\(type.rawValue):\(id)"]?.cachedAt ?? timestamp,
            lastAccessedAt: timestamp,
            removedFromServer: false
        )
    }

    private func recordAudio(
        _ file: CachedAudioFile,
        source: CacheSource,
        triggers: [String]
    ) {
        let key = Self.audioKey(file.songId)
        let previous = rows[key]
        let chosenSource = Self.stronger(source, than: previous.map {
            CacheSource(stored: $0.source)
        })
        let mergedTriggers = Set(Self.triggers(from: previous)).union(triggers)
        let timestamp = nowMilliseconds
        upsert(CacheMetaRecord(
            key: key,
            id: file.songId,
            type: CachedItemType.audio.rawValue,
            source: chosenSource.rawValue,
            triggersJson: Self.encodeTriggers(Array(mergedTriggers).sorted()),
            coverSize: nil,
            sizeBytes: Int(clamping: file.sizeBytes ?? Int64(previous?.sizeBytes ?? 0)),
            cachedAt: previous?.cachedAt ?? timestamp,
            lastAccessedAt: timestamp,
            removedFromServer: previous?.removedFromServer ?? false
        ))
    }

    private func enqueue(songs: [Song], source: CacheSource, triggers: [String]) async {
        guard !songs.isEmpty else { return }
        if pending.isEmpty { didToastBatchFailure = false }
        for song in songs {
            let key = Self.audioKey(song.id)
            if let existing = rows[key], fileExists(for: existing) {
                let nextSource = Self.stronger(
                    source,
                    than: CacheSource(stored: existing.source)
                )
                let merged = Set(Self.triggers(from: existing)).union(triggers)
                var updated = existing
                updated.source = nextSource.rawValue
                updated.triggersJson = Self.encodeTriggers(Array(merged).sorted())
                updated.lastAccessedAt = nowMilliseconds
                upsert(updated)
                continue
            }
            if rows[key] != nil { removeRows(keys: [key]) }
            if let existing = pending[song.id] {
                pending[song.id] = PendingDownload(
                    requestId: existing.requestId,
                    source: Self.stronger(source, than: existing.source),
                    triggers: Array(Set(existing.triggers).union(triggers)).sorted()
                )
                continue
            }
            let requestId = UUID().uuidString
            pending[song.id] = PendingDownload(
                requestId: requestId,
                source: source,
                triggers: triggers
            )
            progress[song.id] = DownloadProgress(loaded: 0, total: 0)
            progressOrder.append(song.id)
            commands.start(song.id, requestId, nil, nil)
        }
        updateActiveDownloads()
    }

    private func updateActiveDownloads() {
        var seen = Set<String>()
        let ids = (progressOrder + progress.keys.sorted()).filter {
            progress[$0] != nil && seen.insert($0).inserted
        }
        let known = ids.compactMap { progress[$0]?.fraction }
        activeDownloads = ActiveDownloadsSummary(
            activeCount: ids.count,
            songIds: ids,
            overallProgress: known.isEmpty
                ? nil
                : known.reduce(0, +) / Double(known.count)
        )
    }

    private func collectionState(key: String) -> CollectionCacheState {
        guard rows[key] != nil else { return .notCached }
        guard let ids = collectionSongIds[key] else { return .notCached }
        let completed = ids.filter { state(ofSong: $0).isCached }.count
        let inFlight = ids.contains { state(ofSong: $0).isDownloading }
        if inFlight { return .downloading(completed: completed, total: ids.count) }
        return completed == ids.count ? .cached : .notCached
    }

    private func hydrateCollectionSongs(generation: UInt64) async {
        let snapshot = rows
        var hydrated: [String: [String]] = [:]
        for row in snapshot.values {
            guard collectionSongIds[row.key] == nil else { continue }
            if row.type == CachedItemType.album.rawValue,
                let detail = await repository.cachedAlbum(id: row.id)
            {
                hydrated[row.key] = detail.songs.map(\.id)
            } else if row.type == CachedItemType.playlist.rawValue,
                let detail = await repository.cachedPlaylist(id: row.id)
            {
                hydrated[row.key] = detail.songs.map(\.id)
            }
        }
        guard generation == lifecycleGeneration else { return }
        collectionSongIds.merge(hydrated) { _, next in next }
        for (key, songIds) in hydrated {
            guard var row = rows[key], row.triggersJson == nil else { continue }
            row.triggersJson = Self.encodeCollectionSongIds(songIds)
            upsert(row)
        }
        revision += 1
    }

    private func removeCollection(key: String) async {
        let affected = Set(collectionSongIds[key] ?? [])
        removeRows(keys: [key])
        let kept = explicitCollectionSongIds()
        for songId in affected {
            await removeExplicitSong(songId, keptByCollections: kept)
        }
        await refreshUsage()
    }

    private func removeExplicitSong(
        _ songId: String,
        keptByCollections: Set<String>
    ) async {
        if keptByCollections.contains(songId) { return }
        if var request = pending[songId], request.source == .explicit {
            if request.triggers.isEmpty {
                cancelPending(songId)
            } else {
                request.source = .smart
                pending[songId] = request
            }
        }
        let key = Self.audioKey(songId)
        guard var row = rows[key], row.source == CacheSource.explicit.rawValue else {
            return
        }
        let triggers = Self.triggers(from: row)
        if !triggers.isEmpty {
            row.source = CacheSource.smart.rawValue
            row.lastAccessedAt = nowMilliseconds
            upsert(row)
            return
        }
        await deleteRow(key: key, deleteFile: true)
    }

    private func cancelPending(_ songId: String) {
        guard pending.removeValue(forKey: songId) != nil else { return }
        progress.removeValue(forKey: songId)
        progressOrder.removeAll { $0 == songId }
        commands.cancel(songId)
        updateActiveDownloads()
        revision += 1
    }

    private func explicitCollectionSongIds() -> Set<String> {
        let markerKeys = Set(rows.values.compactMap { row -> String? in
            guard row.source == CacheSource.explicit.rawValue,
                row.type == CachedItemType.album.rawValue
                    || row.type == CachedItemType.playlist.rawValue
            else { return nil }
            return row.key
        })
        return markerKeys.reduce(into: Set<String>()) { result, key in
            result.formUnion(collectionSongIds[key] ?? [])
        }
    }

    private func deleteRow(key: String, deleteFile: Bool) async {
        guard let row = rows[key] else { return }
        if deleteFile {
            if row.type == CachedItemType.audio.rawValue {
                _ = try? audio.deleteAudioFile(songId: row.id)
            } else if row.type == CachedItemType.cover.rawValue {
                _ = try? library.deleteCover(id: row.id)
            }
        }
        removeRows(keys: [key])
    }

    private func evict(_ candidates: [CacheMetaRecord], quota: Int64) async {
        guard quota > 0 else { return }
        var total = candidates.reduce(Int64(0)) {
            $0 + Int64(max(0, $1.sizeBytes))
        }
        for row in candidates.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }) {
            guard total > quota else { break }
            await deleteRow(key: row.key, deleteFile: true)
            total -= Int64(max(0, row.sizeBytes))
        }
    }

    private func fileExists(for row: CacheMetaRecord) -> Bool {
        switch CachedItemType(rawValue: row.type) {
        case .audio:
            return (try? audio.resolveAudioFile(songId: row.id)) != nil
        case .cover:
            return library.coverSize(id: row.id) != nil
        case .album, .playlist:
            return true
        case nil:
            return false
        }
    }

    private func displayName(
        for row: CacheMetaRecord,
        type: CachedItemType
    ) -> (name: String, subtitle: String?) {
        switch type {
        case .audio:
            let song = try? library.songs(ids: [row.id]).first?.mediaValue
            return (song?.title ?? row.id, song?.artist)
        case .album:
            let album = try? library.album(id: row.id)?.album.mediaValue
            return (album?.name ?? row.id, album?.artist)
        case .playlist:
            let playlist = try? library.playlist(id: row.id)?.mediaValue.playlist
            return (playlist?.name ?? row.id, nil)
        case .cover:
            if let album = try? library.albums(limit: Int.max).items.first(where: {
                $0.coverArt == row.id
            })?.mediaValue {
                return (album.name, album.artist)
            }
            if let artist = try? library.artists(limit: Int.max).items.first(where: {
                $0.coverArt == row.id
            })?.mediaValue {
                return (artist.name, nil)
            }
            return (row.id, nil)
        }
    }

    private var nowMilliseconds: Int {
        Int(now().timeIntervalSince1970 * 1_000)
    }

    private static func audioKey(_ id: String) -> String { "audio:\(id)" }
    private static func albumKey(_ id: String) -> String { "album:\(id)" }
    private static func playlistKey(_ id: String) -> String { "playlist:\(id)" }

    private static func date(milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func stronger(
        _ incoming: CacheSource,
        than existing: CacheSource?
    ) -> CacheSource {
        guard let existing else { return incoming }
        let rank: [CacheSource: Int] = [.lru: 0, .smart: 1, .explicit: 2]
        return (rank[incoming] ?? 0) > (rank[existing] ?? 0) ? incoming : existing
    }

    private static func triggers(from row: CacheMetaRecord?) -> [String] {
        guard let json = row?.triggersJson,
            let data = json.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }

    private static func encodeTriggers(_ values: [String]) -> String? {
        guard !values.isEmpty,
            let data = try? JSONEncoder().encode(values)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeCollectionSongIds(_ values: [String]) -> String {
        let data = try? JSONEncoder().encode(values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

private struct PendingDownload {
    var requestId: String
    var source: CacheSource
    var triggers: [String]
}

private struct DownloadProgress {
    var loaded: Int64
    var total: Int64

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, max(0, Double(loaded) / Double(total)))
    }
}

struct DownloadCommands {
    var start: (String, String, Int?, String?) -> Void
    var cancel: (String?) -> Void

    init(audio: AudioService) {
        start = {
            audio.downloadAudioFile(
                songId: $0,
                requestId: $1,
                maxBitRate: $2,
                format: $3
            )
        }
        cancel = { audio.cancelDownload(songId: $0) }
    }

    init(
        start: @escaping (String, String, Int?, String?) -> Void,
        cancel: @escaping (String?) -> Void
    ) {
        self.start = start
        self.cancel = cancel
    }
}
