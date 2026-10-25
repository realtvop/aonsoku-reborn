import Foundation
import GRDB

protocol LibrarySyncHTTPClient {
    func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String],
        method: String
    ) async throws -> SubsonicResponse
}

extension LibrarySyncHTTPClient {
    func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials
    ) async throws -> SubsonicResponse {
        try await request(
            baseUrl: baseUrl,
            path: path,
            credentials: credentials,
            extraQuery: [:],
            method: "GET"
        )
    }

    func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String]
    ) async throws -> SubsonicResponse {
        try await request(
            baseUrl: baseUrl,
            path: path,
            credentials: credentials,
            extraQuery: extraQuery,
            method: "GET"
        )
    }
}

extension SubsonicHTTPClient: LibrarySyncHTTPClient {}

final class SyncEngine {
    @TaskLocal private static var executingGeneration: Int?

    private let db: DatabasePool
    private let httpClient: any LibrarySyncHTTPClient
    private let syncStateRepo: SyncStateRepository
    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let songRepo: SongRepository
    private let playlistRepo: PlaylistRepository
    private let genreRepo: GenreRepository
    private let cacheMetaRepo: CacheMetaRepository
    private let credentialsProvider: @Sendable () -> ServerCredentials?
    private let cachedCoverSize: @Sendable (String) -> String?
    private let downloadCover: @Sendable (String, String) async throws -> Void

    private let taskLock = NSLock()
    private var currentTask: Task<Bool, Never>?
    private var generation: Int = 0
    private var activeGeneration: Int?

    private var syncStateTimer: Timer?
    private var pendingSyncState: (generation: Int?, state: [String: Any])?

    var onSyncStateChanged: (([String: Any]) -> Void)?
    var onDataChanged: (([String]) -> Void)?

    init(
        db: DatabasePool,
        httpClient: any LibrarySyncHTTPClient,
        credentialsProvider: @escaping @Sendable () -> ServerCredentials? = {
            KeychainManager.retrieve()
        },
        cachedCoverSize: @escaping @Sendable (String) -> String? = { _ in nil },
        downloadCover: @escaping @Sendable (String, String) async throws -> Void = { _, _ in }
    ) {
        self.db = db
        self.httpClient = httpClient
        self.syncStateRepo = SyncStateRepository(db: db)
        self.artistRepo = ArtistRepository(db: db)
        self.albumRepo = AlbumRepository(db: db)
        self.songRepo = SongRepository(db: db)
        self.playlistRepo = PlaylistRepository(db: db)
        self.genreRepo = GenreRepository(db: db)
        self.cacheMetaRepo = CacheMetaRepository(db: db)
        self.credentialsProvider = credentialsProvider
        self.cachedCoverSize = cachedCoverSize
        self.downloadCover = downloadCover
    }

    func syncAll(
        includeFullSongs: Bool = true,
        mode: String = "full",
        coverArt: LibrarySyncOptions.CoverArt? = nil
    ) {
        startSync(
            includeFullSongs: includeFullSongs,
            mode: mode,
            coverArt: coverArt
        )
    }

    func syncAllAndWait(
        includeFullSongs: Bool = true,
        mode: String = "full",
        coverArt: LibrarySyncOptions.CoverArt? = nil
    ) async -> Bool {
        let handle = startSync(
            includeFullSongs: includeFullSongs,
            mode: mode,
            coverArt: coverArt
        )
        let result = await handle.task.value
        finishSync(generation: handle.generation)
        return result
    }

    private struct SyncHandle {
        let generation: Int
        let task: Task<Bool, Never>
    }

    @discardableResult
    private func startSync(
        includeFullSongs: Bool,
        mode: String,
        coverArt: LibrarySyncOptions.CoverArt?
    ) -> SyncHandle {
        let (gen, previousTask) = taskLock.withLock {
            generation &+= 1
            activeGeneration = generation
            let previousTask = currentTask
            currentTask = nil
            return (generation, previousTask)
        }
        previousTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await Self.$executingGeneration.withValue(gen) {
                await self.performSync(
                    generation: gen,
                    includeFullSongs: includeFullSongs,
                    mode: mode,
                    coverArt: coverArt
                )
            }
        }
        let accepted = taskLock.withLock {
            guard generation == gen, activeGeneration == gen else { return false }
            currentTask = task
            return true
        }
        if !accepted { task.cancel() }
        Task { [weak self] in
            _ = await task.value
            self?.finishSync(generation: gen)
        }
        return SyncHandle(generation: gen, task: task)
    }

    func syncIncremental() {
        syncAll(includeFullSongs: true, mode: "incremental")
    }

    func cancel() {
        let (task, cancellationGeneration) = taskLock.withLock {
            () -> (Task<Bool, Never>?, Int) in
            generation &+= 1
            activeGeneration = nil
            let task = currentTask
            currentTask = nil
            return (task, generation)
        }
        task?.cancel()
        enqueueState(
            phase: "cancelled",
            tier: nil,
            processed: 0,
            total: 0,
            message: nil,
            generation: cancellationGeneration
        )
        forceFlushSyncState()
    }

    var isSyncing: Bool {
        taskLock.withLock { activeGeneration != nil }
    }

    // MARK: - Private

    private func performSync(
        generation: Int,
        includeFullSongs: Bool,
        mode: String,
        coverArt: LibrarySyncOptions.CoverArt?
    ) async -> Bool {
        guard let credentials = credentialsProvider() else {
            emitState(
                phase: "error",
                tier: nil,
                processed: 0,
                total: 0,
                message: "Not signed in"
            )
            forceFlushSyncState()
            return false
        }

        emitState(phase: "idle", tier: nil, processed: 0, total: 0)

        do {
            if !shouldSkipTier(.t1, mode: mode) {
                try await runT1(credentials: credentials)
            }
            try Task.checkCancellation()
            guard isCurrentGeneration(generation) else { throw CancellationError() }

            if !shouldSkipTier(.t2, mode: mode) {
                try await runT2(credentials: credentials)
            }
            try Task.checkCancellation()
            guard isCurrentGeneration(generation) else { throw CancellationError() }

            if includeFullSongs && !shouldSkipTier(.t3, mode: mode) {
                try await runT3(credentials: credentials)
            }
            try Task.checkCancellation()
            guard isCurrentGeneration(generation) else { throw CancellationError() }

            if let coverArt {
                try await runCoverArt(options: coverArt, serverType: credentials.serverType)
            }
            try Task.checkCancellation()
            guard isCurrentGeneration(generation) else { throw CancellationError() }

            try? syncStateRepo.recordFullSync()
            emitState(phase: "done", tier: nil, processed: 0, total: 0)
            forceFlushSyncState()
            return true
        } catch is CancellationError {
            emitState(phase: "cancelled", tier: nil, processed: 0, total: 0)
            forceFlushSyncState()
        } catch {
            NativeLogger.shared.error("sync failed: \(error)", source: "Sync")
            emitState(
                phase: "error",
                tier: nil,
                processed: 0,
                total: 0,
                message: error.localizedDescription
            )
            forceFlushSyncState()
        }

        return false
    }

    private func finishSync(generation: Int) {
        taskLock.withLock {
            guard activeGeneration == generation else { return }
            activeGeneration = nil
            currentTask = nil
        }
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        taskLock.withLock { self.generation == generation }
    }

    // MARK: - Cover Art

    func runCoverArt(
        options: LibrarySyncOptions.CoverArt,
        serverType: String
    ) async throws {
        try Task.checkCancellation()
        let identifiers = try coverArtIdentifiers(
            useAlbumCoverForSongs: options.useAlbumCoverForSongs,
            serverType: serverType
        )
        let total = identifiers.count
        var processed = 0
        var pending: [String] = []
        pending.reserveCapacity(total)

        for id in identifiers {
            if coverSize(cachedCoverSize(id), satisfies: options.size) {
                processed += 1
            } else {
                pending.append(id)
            }
        }
        emitState(phase: "coverArt", tier: nil, processed: processed, total: total)
        forceFlushSyncState()

        let concurrency = min(max(options.concurrency, 1), 8)
        for offset in stride(from: 0, to: pending.count, by: concurrency) {
            try Task.checkCancellation()
            let batch = Array(pending[offset..<min(offset + concurrency, pending.count)])
            let size = options.size
            let downloader = downloadCover
            let failures = await withTaskGroup(of: (String, String?).self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            try await downloader(id, size)
                            return (id, nil)
                        } catch is CancellationError {
                            return (id, "cancelled")
                        } catch {
                            return (id, error.localizedDescription)
                        }
                    }
                }
                var values: [(String, String?)] = []
                for await value in group { values.append(value) }
                return values
            }
            try Task.checkCancellation()
            for (id, failure) in failures {
                if let failure, failure != "cancelled" {
                    NativeLogger.shared.error(
                        "cover download failed for \(id): \(failure)",
                        source: "Sync"
                    )
                }
                processed += 1
                emitState(
                    phase: "coverArt",
                    tier: nil,
                    processed: processed,
                    total: total
                )
            }
        }
        forceFlushSyncState()
    }

    private func coverArtIdentifiers(
        useAlbumCoverForSongs: Bool,
        serverType: String
    ) throws -> [String] {
        try db.read { db in
            var values: [String] = []
            values += try String.fetchAll(
                db,
                sql: "SELECT coverArt FROM artist WHERE coverArt IS NOT NULL AND coverArt != ''"
            )
            if serverType.lowercased() != "lms" {
                values += try String.fetchAll(db, sql: "SELECT id FROM artist")
            }
            values += try String.fetchAll(
                db,
                sql: "SELECT coverArt FROM album WHERE coverArt IS NOT NULL AND coverArt != ''"
            )
            if useAlbumCoverForSongs {
                values += try String.fetchAll(db, sql: "SELECT id FROM album")
            }
            values += try String.fetchAll(
                db,
                sql: "SELECT coverArt FROM playlist WHERE coverArt IS NOT NULL AND coverArt != ''"
            )
            if !useAlbumCoverForSongs {
                values += try String.fetchAll(
                    db,
                    sql: "SELECT coverArt FROM song WHERE coverArt IS NOT NULL AND coverArt != ''"
                )
            }
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
    }

    private func coverSize(_ cached: String?, satisfies requested: String) -> Bool {
        guard let cached else { return false }
        if let cachedPixels = Int(cached), let requestedPixels = Int(requested) {
            return cachedPixels >= requestedPixels
        }
        return cached == requested
    }

    func refreshPlaylist(id: String) async throws {
        guard let credentials = credentialsProvider() else {
            throw SubsonicAPIError.notSignedIn
        }
        let response = try await httpClient.request(
            baseUrl: credentials.serverUrl,
            path: "getPlaylist.view",
            credentials: credentials,
            extraQuery: ["id": id]
        )
        guard let detail = parsePlaylistDetail(from: response.data) else {
            throw SubsonicAPIError.invalidResponse("Missing playlist")
        }
        let playlist = PlaylistRecord(
            id: detail.id,
            name: detail.name,
            comment: detail.comment,
            songCount: detail.songCount,
            duration: detail.duration,
            isPublic: detail.isPublic,
            owner: detail.owner,
            created: detail.created,
            changed: detail.changed,
            coverArt: detail.coverArt,
            starred: detail.starred,
            starredAt: detail.starredAt
        )
        try playlistRepo.upsert(playlist, detail: detail)
    }

    // MARK: - T1: Genres, Playlists, Favorites

    private func runT1(credentials: ServerCredentials) async throws {
        try Task.checkCancellation()
        emitState(phase: "genres", tier: "t1", processed: 0, total: 0)

        let genreResponse = try await httpClient.request(
            baseUrl: credentials.serverUrl,
            path: "getGenres.view",
            credentials: credentials
        )
        try Task.checkCancellation()

        let genres = parseGenres(from: genreResponse.data)
        try Task.checkCancellation()
        try genreRepo.replaceAll(genres)

        try Task.checkCancellation()
        emitState(phase: "playlists", tier: "t1", processed: 0, total: 0)

        let playlistsResponse = try await httpClient.request(
            baseUrl: credentials.serverUrl,
            path: "getPlaylists.view",
            credentials: credentials
        )
        try Task.checkCancellation()

        let playlists = parsePlaylists(from: playlistsResponse.data)
        try Task.checkCancellation()
        try playlistRepo.bulkUpsert(playlists)
        try await syncPlaylistDetails(playlists: playlists, credentials: credentials)

        try Task.checkCancellation()
        emitState(phase: "favorites", tier: "t1", processed: 0, total: 0)

        let starredResponse = try await httpClient.request(
            baseUrl: credentials.serverUrl,
            path: "getStarred2.view",
            credentials: credentials
        )
        try Task.checkCancellation()

        let starredSongs = parseStarredSongs(from: starredResponse.data)
        if !starredSongs.isEmpty {
            try Task.checkCancellation()
            try songRepo.bulkUpsert(starredSongs)
        }

        try Task.checkCancellation()
        try syncStateRepo.recordTierCheckpoint(tier: "t1")
        forceFlushSyncState()
        onDataChanged?(["playlists", "genres", "favorites", "songs"])
    }

    // MARK: - T2: Artists, Albums

    private func runT2(credentials: ServerCredentials) async throws {
        try Task.checkCancellation()
        emitState(phase: "artists", tier: "t2", processed: 0, total: 0)

        let artistsResponse = try await httpClient.request(
            baseUrl: credentials.serverUrl,
            path: "getArtists.view",
            credentials: credentials
        )
        try Task.checkCancellation()

        let artists = parseArtists(from: artistsResponse.data)
        try Task.checkCancellation()
        try await db.write { db in
            _ = try ArtistRecord.deleteAll(db)
            for artist in artists {
                try artist.save(db, onConflict: .replace)
            }
        }

        try Task.checkCancellation()
        emitState(phase: "albums", tier: "t2", processed: 0, total: 0)

        var allAlbums: [AlbumRecord] = []
        var albumOffset = 0
        let albumPageSize = 500
        var hasMoreAlbums = true

        while hasMoreAlbums {
            try Task.checkCancellation()

            let result = try await httpClient.request(
                baseUrl: credentials.serverUrl,
                path: "getAlbumList2.view",
                credentials: credentials,
                extraQuery: [
                    "type": "alphabeticalByName",
                    "size": "\(albumPageSize)",
                    "offset": "\(albumOffset)",
                ]
            )

            let albums = parseAlbumList(from: result.data)
            if albums.isEmpty {
                hasMoreAlbums = false
            } else {
                allAlbums.append(contentsOf: albums)
                emitState(phase: "albums", tier: "t2", processed: allAlbums.count, total: result.count > 0 ? result.count : allAlbums.count)
                albumOffset += albumPageSize
                if albums.count < albumPageSize {
                    hasMoreAlbums = false
                }
            }
        }

        try Task.checkCancellation()
        let albumsToStore = allAlbums
        try await db.write { db in
            _ = try AlbumRecord.deleteAll(db)
            for album in albumsToStore {
                try album.save(db, onConflict: .replace)
            }
        }

        try Task.checkCancellation()
        try syncStateRepo.recordTierCheckpoint(tier: "t2")
        forceFlushSyncState()
        onDataChanged?(["artists", "albums"])
    }

    // MARK: - T3: All Songs

    private func runT3(credentials: ServerCredentials) async throws {
        try Task.checkCancellation()
        emitState(phase: "songs", tier: "t3", processed: 0, total: 0)

        let searchAllQuery = buildAllSongsQuery(serverType: credentials.serverType)
        let pageSize = 500
        var allSongs: [SongRecord] = []
        var songOffset = 0
        var hasMoreSongs = true

        while hasMoreSongs {
            try Task.checkCancellation()

            let result = try await httpClient.request(
                baseUrl: credentials.serverUrl,
                path: "search3.view",
                credentials: credentials,
                extraQuery: [
                    "query": searchAllQuery,
                    "artistCount": "0",
                    "artistOffset": "0",
                    "albumCount": "0",
                    "albumOffset": "0",
                    "songCount": "\(pageSize)",
                    "songOffset": "\(songOffset)",
                ]
            )

            let songs = parseSearchSongs(from: result.data)
            if songs.isEmpty {
                hasMoreSongs = false
            } else {
                allSongs.append(contentsOf: songs)
                songOffset += songs.count
                emitState(phase: "songs", tier: "t3", processed: allSongs.count, total: 100000)
                if songs.count < pageSize {
                    hasMoreSongs = false
                }
            }
        }

        try Task.checkCancellation()
        try songRepo.bulkUpsert(allSongs)

        if !allSongs.isEmpty {
            let serverIds = Set(allSongs.map { $0.id })
            let allExistingIds = try await db.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM song")
            }
            let staleIds = allExistingIds.filter { !serverIds.contains($0) }
            let maxDeletions = Int(ceil(Double(allSongs.count) * 0.1))

            if !staleIds.isEmpty && staleIds.count <= maxDeletions {
                try Task.checkCancellation()
                try await db.write { db in
                    _ = try SongRecord.filter(staleIds.contains(Column("id"))).deleteAll(db)
                }
            }
            try reconcileCachedSongs(
                serverIds: serverIds,
                staleSongCount: staleIds.count,
                serverSongCount: allSongs.count
            )
        }

        emitState(phase: "songs", tier: "t3", processed: allSongs.count, total: allSongs.count)
        try Task.checkCancellation()
        try syncStateRepo.recordTierCheckpoint(tier: "t3")
        forceFlushSyncState()
        onDataChanged?(["songs", "favorites"])
    }

    /// Marks cached audio whose song disappeared from an authoritative song
    /// listing. Large unexpected removals retain their prior state, matching
    /// the song-table deletion safety threshold, while reappearing songs are
    /// always restored immediately.
    func reconcileCachedSongs(
        serverIds: Set<String>,
        staleSongCount: Int,
        serverSongCount: Int
    ) throws {
        guard serverSongCount > 0 else { return }
        let maxRemovals = Int(ceil(Double(serverSongCount) * 0.1))
        let canMarkMissing = staleSongCount <= maxRemovals
        var updates: [CacheMetaRecord] = []

        for var row in try cacheMetaRepo.getAll(type: "audio") {
            let removed: Bool
            if serverIds.contains(row.id) {
                removed = false
            } else if canMarkMissing {
                removed = true
            } else {
                continue
            }
            guard row.removedFromServer != removed else { continue }
            row.removedFromServer = removed
            updates.append(row)
        }
        if !updates.isEmpty {
            try cacheMetaRepo.bulkUpsert(updates)
        }
    }

    // MARK: - Playlist Details

    private func syncPlaylistDetails(playlists: [PlaylistRecord], credentials: ServerCredentials) async throws {
        try Task.checkCancellation()
        let playlistIds = Set(playlists.map { $0.id })
        let existingIds = try playlistRepo.getAllDetailIds()
        let removedIds = existingIds.filter { !playlistIds.contains($0) }

        if !removedIds.isEmpty && !playlists.isEmpty && removedIds.count < existingIds.count {
            try Task.checkCancellation()
            try playlistRepo.deleteDetails(ids: removedIds)
        }

        let batchSize = 25
        for offset in stride(from: 0, to: playlists.count, by: batchSize) {
            try Task.checkCancellation()

            let batch = Array(playlists[offset..<min(offset + batchSize, playlists.count)])
            var details: [PlaylistDetailRecord] = []

            for playlist in batch {
                do {
                    let response = try await httpClient.request(
                        baseUrl: credentials.serverUrl,
                        path: "getPlaylist.view",
                        credentials: credentials,
                        extraQuery: ["id": playlist.id]
                    )
                    if let detail = parsePlaylistDetail(from: response.data) {
                        details.append(detail)
                    }
                } catch {
                    NativeLogger.shared.error("failed to load playlist detail \(playlist.id): \(error)", source: "Sync")
                }
            }

            if !details.isEmpty {
                try Task.checkCancellation()
                try playlistRepo.bulkUpsertDetails(details)
            }

            emitState(phase: "playlists", tier: "t1",
                      processed: min(offset + batch.count, playlists.count),
                      total: playlists.count)
        }
    }

    // MARK: - Helpers

    private func shouldSkipTier(_ tier: SyncTier, mode: String) -> Bool {
        if mode == "full" { return false }
        guard let lastSynced = try? syncStateRepo.getLastSyncedAt(tier: tier.rawValue) else {
            return false
        }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return tier.isFresh(lastSyncedAtMs: lastSynced, nowMs: now)
    }

    private func emitState(
        phase: String,
        tier: String?,
        processed: Int,
        total: Int,
        message: String? = nil
    ) {
        enqueueState(
            phase: phase,
            tier: tier,
            processed: processed,
            total: total,
            message: message,
            generation: Self.executingGeneration
        )
    }

    private func enqueueState(
        phase: String,
        tier: String?,
        processed: Int,
        total: Int,
        message: String?,
        generation: Int?
    ) {
        if let generation, !isCurrentGeneration(generation) { return }
        var state: [String: Any] = [
            "phase": phase,
            "tier": tier as Any,
            "isSyncing": phase != "done" && phase != "error" && phase != "cancelled",
            "progress": total > 0 ? Int((Double(processed) / Double(total)) * 100) : 0,
            "processedItems": processed,
            "totalItems": total,
        ]
        if let message { state["message"] = message }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let generation, !self.isCurrentGeneration(generation) { return }
            self.pendingSyncState = (generation, state)
            if self.syncStateTimer == nil {
                self.syncStateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    self?.flushSyncState()
                }
            }
        }
    }

    private func flushSyncState() {
        syncStateTimer = nil
        guard let pending = pendingSyncState else { return }
        pendingSyncState = nil
        if let generation = pending.generation,
           !isCurrentGeneration(generation) {
            return
        }
        onSyncStateChanged?(pending.state)
    }

    private func forceFlushSyncState() {
        DispatchQueue.main.async { [weak self] in
            self?.syncStateTimer?.invalidate()
            self?.syncStateTimer = nil
            self?.flushSyncState()
        }
    }

    // MARK: - JSON Parsing

    private func parseGenres(from data: [String: Any]) -> [GenreRecord] {
        guard let genres = data["genres"] as? [String: Any],
              let genreList = genres["genre"] as? [[String: Any]] else {
            return []
        }
        return genreList.compactMap { item in
            guard let value = item["value"] as? String else { return nil }
            return GenreRecord(
                value: value,
                songCount: item["songCount"] as? Int,
                albumCount: item["albumCount"] as? Int
            )
        }
    }

    private func parsePlaylists(from data: [String: Any]) -> [PlaylistRecord] {
        guard let playlists = data["playlists"] as? [String: Any],
              let list = playlists["playlist"] as? [[String: Any]] else {
            return []
        }
        return list.compactMap { parsePlaylistRecord($0) }
    }

    private func parsePlaylistRecord(_ item: [String: Any]) -> PlaylistRecord? {
        guard let id = item["id"] as? String,
              let name = item["name"] as? String else { return nil }
        return PlaylistRecord(
            id: id,
            name: name,
            comment: item["comment"] as? String,
            songCount: item["songCount"] as? Int ?? 0,
            duration: item["duration"] as? Int ?? 0,
            isPublic: item["public"] as? Bool ?? false,
            owner: item["owner"] as? String,
            created: item["created"] as? String,
            changed: item["changed"] as? String,
            coverArt: item["coverArt"] as? String,
            starred: item["starred"] as? String,
            starredAt: toEpoch(item["starred"] as? String)
        )
    }

    private func parsePlaylistDetail(from data: [String: Any]) -> PlaylistDetailRecord? {
        guard let playlist = data["playlist"] as? [String: Any],
              let id = playlist["id"] as? String,
              let name = playlist["name"] as? String else { return nil }

        let entries = playlist["entry"] as? [[String: Any]] ?? []
        let entriesJson = (try? JSONSerialization.data(withJSONObject: entries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return PlaylistDetailRecord(
            id: id,
            name: name,
            comment: playlist["comment"] as? String,
            songCount: playlist["songCount"] as? Int ?? 0,
            duration: playlist["duration"] as? Int ?? 0,
            isPublic: playlist["public"] as? Bool ?? false,
            owner: playlist["owner"] as? String,
            created: playlist["created"] as? String,
            changed: playlist["changed"] as? String,
            coverArt: playlist["coverArt"] as? String,
            starred: playlist["starred"] as? String,
            starredAt: toEpoch(playlist["starred"] as? String),
            entriesJson: entriesJson
        )
    }

    private func parseArtists(from data: [String: Any]) -> [ArtistRecord] {
        guard let artists = data["artists"] as? [String: Any],
              let index = artists["index"] as? [[String: Any]] else {
            return []
        }
        var result: [ArtistRecord] = []
        for group in index {
            guard let artistList = group["artist"] as? [[String: Any]] else { continue }
            for item in artistList {
                if let record = parseArtistRecord(item) {
                    result.append(record)
                }
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    private func parseArtistRecord(_ item: [String: Any]) -> ArtistRecord? {
        guard let id = item["id"] as? String,
              let name = item["name"] as? String else { return nil }
        return ArtistRecord(
            id: id,
            name: name,
            albumCount: item["albumCount"] as? Int ?? 0,
            coverArt: item["coverArt"] as? String,
            artistImageUrl: item["artistImageUrl"] as? String,
            starred: item["starred"] as? String,
            starredAt: toEpoch(item["starred"] as? String),
            musicBrainzId: item["musicBrainzId"] as? String,
            sortName: item["sortName"] as? String
        )
    }

    private func parseAlbumList(from data: [String: Any]) -> [AlbumRecord] {
        guard let albumList2 = data["albumList2"] as? [String: Any],
              let albums = albumList2["album"] as? [[String: Any]] else {
            return []
        }
        return albums.compactMap { parseAlbumRecord($0) }
    }

    private func parseAlbumRecord(_ item: [String: Any]) -> AlbumRecord? {
        guard let id = item["id"] as? String,
              let name = item["name"] as? String else { return nil }
        return AlbumRecord(
            id: id,
            name: name,
            artist: item["artist"] as? String ?? "",
            artistId: item["artistId"] as? String,
            coverArt: item["coverArt"] as? String,
            songCount: item["songCount"] as? Int ?? 0,
            duration: item["duration"] as? Int ?? 0,
            year: item["year"] as? Int,
            genre: item["genre"] as? String,
            created: item["created"] as? String,
            played: item["played"] as? String,
            playCount: item["playCount"] as? Int,
            starred: item["starred"] as? String,
            starredAt: toEpoch(item["starred"] as? String)
        )
    }

    private func parseStarredSongs(from data: [String: Any]) -> [SongRecord] {
        guard let starred2 = data["starred2"] as? [String: Any],
              let songs = starred2["song"] as? [[String: Any]] else {
            return []
        }
        return songs.compactMap { parseSongRecord($0) }
    }

    private func parseSearchSongs(from data: [String: Any]) -> [SongRecord] {
        guard let searchResult3 = data["searchResult3"] as? [String: Any],
              let songs = searchResult3["song"] as? [[String: Any]] else {
            return []
        }
        return songs.compactMap { parseSongRecord($0) }
    }

    private func parseSongRecord(_ item: [String: Any]) -> SongRecord? {
        guard let id = item["id"] as? String,
              let title = item["title"] as? String else { return nil }

        var genresJson: String?
        if let genres = item["genres"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: genres) {
            genresJson = String(data: data, encoding: .utf8)
        }

        var replayGainJson: String?
        if let rg = item["replayGain"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: rg) {
            replayGainJson = String(data: data, encoding: .utf8)
        }

        return SongRecord(
            id: id,
            parent: item["parent"] as? String,
            title: title,
            album: item["album"] as? String,
            artist: item["artist"] as? String,
            track: item["track"] as? Int,
            year: item["year"] as? Int,
            genre: item["genre"] as? String,
            coverArt: item["coverArt"] as? String,
            size: item["size"] as? Int,
            contentType: item["contentType"] as? String,
            suffix: item["suffix"] as? String,
            duration: item["duration"] as? Int ?? 0,
            bitRate: item["bitRate"] as? Int,
            path: item["path"] as? String,
            playCount: item["playCount"] as? Int,
            discNumber: item["discNumber"] as? Int,
            created: item["created"] as? String,
            albumId: item["albumId"] as? String,
            artistId: item["artistId"] as? String,
            played: item["played"] as? String,
            starred: item["starred"] as? String,
            starredAt: toEpoch(item["starred"] as? String),
            playedAt: toEpoch(item["played"] as? String),
            bpm: item["bpm"] as? Int,
            comment: item["comment"] as? String,
            sortName: item["sortName"] as? String,
            mediaType: item["mediaType"] as? String,
            musicBrainzId: item["musicBrainzId"] as? String,
            genresJson: genresJson,
            replayGainJson: replayGainJson
        )
    }

    private func toEpoch(_ iso: String?) -> Int? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) {
            return Int(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}

func buildAllSongsQuery(serverType: String) -> String {
    serverType == "navidrome" ? "\"\"" : ""
}
