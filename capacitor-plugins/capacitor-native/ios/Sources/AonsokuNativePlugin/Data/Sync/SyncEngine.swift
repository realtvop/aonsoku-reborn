import Foundation
import GRDB

final class SyncEngine {
    private let db: DatabasePool
    private let httpClient: SubsonicHTTPClient
    private let syncStateRepo: SyncStateRepository
    private let artistRepo: ArtistRepository
    private let albumRepo: AlbumRepository
    private let songRepo: SongRepository
    private let playlistRepo: PlaylistRepository
    private let genreRepo: GenreRepository
    private let cacheMetaRepo: CacheMetaRepository

    private var currentTask: Task<Void, Never>?
    private var generation: Int = 0

    private var syncStateTimer: Timer?
    private var pendingSyncState: [String: Any]?

    var onSyncStateChanged: (([String: Any]) -> Void)?
    var onDataChanged: (([String]) -> Void)?

    init(db: DatabasePool, httpClient: SubsonicHTTPClient) {
        self.db = db
        self.httpClient = httpClient
        self.syncStateRepo = SyncStateRepository(db: db)
        self.artistRepo = ArtistRepository(db: db)
        self.albumRepo = AlbumRepository(db: db)
        self.songRepo = SongRepository(db: db)
        self.playlistRepo = PlaylistRepository(db: db)
        self.genreRepo = GenreRepository(db: db)
        self.cacheMetaRepo = CacheMetaRepository(db: db)
    }

    func syncAll(includeFullSongs: Bool = true, mode: String = "full") {
        let gen = generation + 1
        generation = gen

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.performSync(generation: gen, includeFullSongs: includeFullSongs, mode: mode)
        }
    }

    func syncIncremental() {
        syncAll(includeFullSongs: true, mode: "incremental")
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    var isSyncing: Bool {
        currentTask != nil && !currentTask!.isCancelled
    }

    // MARK: - Private

    private func performSync(generation: Int, includeFullSongs: Bool, mode: String) async {
        guard let credentials = KeychainManager.retrieve() else {
            emitState(phase: "error", tier: nil, processed: 0, total: 0)
            forceFlushSyncState()
            return
        }

        emitState(phase: "idle", tier: nil, processed: 0, total: 0)

        do {
            if !shouldSkipTier(.t1, mode: mode) {
                try await runT1(credentials: credentials)
            }
            guard self.generation == generation, !Task.isCancelled else { return }

            if !shouldSkipTier(.t2, mode: mode) {
                try await runT2(credentials: credentials)
            }
            guard self.generation == generation, !Task.isCancelled else { return }

            if includeFullSongs && !shouldSkipTier(.t3, mode: mode) {
                try await runT3(credentials: credentials)
            }
            guard self.generation == generation, !Task.isCancelled else { return }

            try? syncStateRepo.recordFullSync()
            emitState(phase: "done", tier: nil, processed: 0, total: 0)
            forceFlushSyncState()
        } catch is CancellationError {
            emitState(phase: "cancelled", tier: nil, processed: 0, total: 0)
            forceFlushSyncState()
        } catch {
            NativeLogger.shared.error("sync failed: \(error)", source: "Sync")
            emitState(phase: "error", tier: nil, processed: 0, total: 0)
            forceFlushSyncState()
        }

        if self.generation == generation {
            currentTask = nil
        }
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
            try songRepo.bulkUpsert(starredSongs)
        }

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

        try await db.write { db in
            _ = try AlbumRecord.deleteAll(db)
            for album in allAlbums {
                try album.save(db, onConflict: .replace)
            }
        }

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

        try songRepo.bulkUpsert(allSongs)

        if !allSongs.isEmpty {
            let serverIds = Set(allSongs.map { $0.id })
            let allExistingIds = try await db.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM song")
            }
            let staleIds = allExistingIds.filter { !serverIds.contains($0) }
            let maxDeletions = Int(ceil(Double(allSongs.count) * 0.1))

            if !staleIds.isEmpty && staleIds.count <= maxDeletions {
                try await db.write { db in
                    _ = try SongRecord.filter(staleIds.contains(Column("id"))).deleteAll(db)
                }
            }
        }

        emitState(phase: "songs", tier: "t3", processed: allSongs.count, total: allSongs.count)
        try syncStateRepo.recordTierCheckpoint(tier: "t3")
        forceFlushSyncState()
        onDataChanged?(["songs", "favorites"])
    }

    // MARK: - Playlist Details

    private func syncPlaylistDetails(playlists: [PlaylistRecord], credentials: ServerCredentials) async throws {
        let playlistIds = Set(playlists.map { $0.id })
        let existingIds = try playlistRepo.getAllDetailIds()
        let removedIds = existingIds.filter { !playlistIds.contains($0) }

        if !removedIds.isEmpty && !playlists.isEmpty && removedIds.count < existingIds.count {
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

    private func emitState(phase: String, tier: String?, processed: Int, total: Int) {
        let state: [String: Any] = [
            "phase": phase,
            "tier": tier as Any,
            "isSyncing": phase != "done" && phase != "error" && phase != "cancelled",
            "progress": total > 0 ? Int((Double(processed) / Double(total)) * 100) : 0,
            "processedItems": processed,
            "totalItems": total,
        ]
        pendingSyncState = state
        if syncStateTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.syncStateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    self?.flushSyncState()
                }
            }
        }
    }

    private func flushSyncState() {
        syncStateTimer = nil
        guard let state = pendingSyncState else { return }
        pendingSyncState = nil
        onSyncStateChanged?(state)
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
