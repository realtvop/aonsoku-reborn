import Foundation
import GRDB

extension Notification.Name {
    static let aonsokuNativeLibraryChanged = Notification.Name("AonsokuNativeLibraryChanged")
}

/// Native reads work before the phone scene or Capacitor bridge exists.
public final class CarPlayLibraryProvider {
    private let db: DatabasePool
    private let credentials: () -> ServerCredentials?
    private let cacheDirectories: [URL]
    private let http: SubsonicHTTPClient
    private let queryQueue = DispatchQueue(label: "com.aonsoku.carplay.library", qos: .userInitiated)

    public convenience init() {
        self.init(
            db: DatabaseManager.shared.dbPool, credentials: { KeychainManager.retrieve() },
            cacheDirectories: NativeSourceResolver().cacheDirectories)
    }

    init(
        db: DatabasePool, credentials: @escaping () -> ServerCredentials?, cacheDirectories: [URL],
        http: SubsonicHTTPClient = SubsonicHTTPClient()
    ) {
        self.db = db
        self.http = http
        self.credentials = credentials
        self.cacheDirectories = cacheDirectories
    }

    public func page(_ route: CarPlayLibraryRoute, offset: Int = 0, limit: Int = 40) async throws -> CarPlayLibraryPage
    {
        try Task.checkCancellation()
        guard let identity = credentials() else { throw CarPlayError.notLoggedIn }
        if case .playlist(let id) = route { try await ensurePlaylist(id) }
        let result = try await read {
            let offset = max(0, offset)
            let limit = max(1, min(limit, Int.max - 1))
            let items = try self.items(route, limit: limit + 1, offset: offset)
            return CarPlayLibraryPage(
                items: Array(items.prefix(limit)),
                nextOffset: items.count > limit ? offset + limit : nil)
        }
        try Task.checkCancellation()
        guard sameAccount(identity) else { throw CancellationError() }
        return result
    }

    /// Album/playlist playback retains the complete context and duplicate entries.
    /// Other collections use the displayed page as a bounded playback context.
    func selection(
        _ route: CarPlayLibraryRoute, pageOffset: Int, pageLimit: Int = 40,
        index: Int, expectedId: String
    ) async throws -> [QueueSong]
    {
        try Task.checkCancellation()
        guard let identity = credentials() else { throw CarPlayError.notLoggedIn }
        if case .playlist(let id) = route { try await ensurePlaylist(id) }
        let result = try await read {
            let songs: [SongRecord]
            switch route {
            case .album: songs = try self.songRecords(route, limit: Int.max, offset: 0)
            case .playlist(let id): songs = try self.playlistSongs(id)
            default: songs = try self.songRecords(route, limit: max(1, pageLimit), offset: pageOffset)
            }
            let localIndex: Int
            switch route {
            case .album, .playlist: localIndex = index
            default: localIndex = index - pageOffset
            }
            guard songs.indices.contains(localIndex), songs[localIndex].id == expectedId else {
                throw CarPlayError.staleSelection
            }
            if route == .downloaded, !self.isDownloaded(expectedId) { throw CarPlayError.unavailable }
            let preferences = PreferencesManager(db: self.db)
            let settings = preferences.getString(SettingsStore.storageKey)?.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
            let albumCover = settings?.playback.useAlbumCoverForSongs ?? false
            return songs.map { $0.toQueueSong(useAlbumCoverForSongs: albumCover) }
        }
        try Task.checkCancellation()
        guard sameAccount(identity) else { throw CancellationError() }
        return result
    }

    public func coverData(_ id: String) async throws -> Data? {
        try Task.checkCancellation()
        guard let identity = credentials() else { return nil }
        let manager = ImageCacheManager(db: db)
        if let cached = try await read({ manager.resolveCoverImage(coverArtId: id).flatMap { try? Data(contentsOf: $0) } }) { return cached }
        _ = try await manager.downloadCoverImage(coverArtId: id, size: "128")
        try Task.checkCancellation()
        guard sameAccount(identity) else { throw CancellationError() }
        return try await read { manager.resolveCoverImage(coverArtId: id).flatMap { try? Data(contentsOf: $0) } }
    }

    private func read<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queryQueue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private func items(_ route: CarPlayLibraryRoute, limit: Int, offset: Int) throws -> [CarPlayLibraryItem] {
        switch route {
        case .albums, .artist:
            var filter = AlbumQueryFilter()
            if case .artist(let id) = route { filter.artistId = id }
            return try AlbumRepository(db: db).getAll(limit: limit, offset: offset, filter: filter).items.map {
                CarPlayLibraryItem(
                    id: $0.id, title: $0.name, detail: $0.artist, coverArtId: $0.coverArt,
                    destination: .album($0.id), songIndex: nil)
            }
        case .artists:
            return try ArtistRepository(db: db).getAll(limit: limit, offset: offset, filter: ArtistQueryFilter()).items
                .map {
                    CarPlayLibraryItem(
                        id: $0.id, title: $0.name, detail: "\($0.albumCount)", coverArtId: $0.coverArt,
                        destination: .artist($0.id), songIndex: nil)
                }
        case .playlists:
            return try PlaylistRepository(db: db).getAll(limit: limit, offset: offset).items.map {
                CarPlayLibraryItem(
                    id: $0.id, title: $0.name, detail: "\($0.songCount)", coverArtId: $0.coverArt,
                    destination: .playlist($0.id), songIndex: nil)
            }
        default:
            return try songRecords(route, limit: limit, offset: offset).enumerated().map { index, song in
                CarPlayLibraryItem(
                    id: song.id, title: song.title, detail: song.artist ?? "",
                    coverArtId: song.coverArt ?? song.albumId, destination: nil, songIndex: offset + index)
            }
        }
    }

    private func songRecords(_ route: CarPlayLibraryRoute, limit: Int, offset: Int) throws -> [SongRecord] {
        if case .playlist(let id) = route { return Array(try playlistSongs(id).dropFirst(offset).prefix(limit)) }
        if route == .recent {
            return try db.read { db in
                try SongRecord.fetchAll(
                    db,
                    sql: """
                        SELECT song.* FROM song LEFT JOIN (
                            SELECT json_extract(songJson, '$.id') AS songId, MAX(playedAt) AS lastPlayed
                            FROM playHistory GROUP BY songId
                        ) history ON song.id = history.songId
                        WHERE history.lastPlayed IS NOT NULL OR song.playedAt IS NOT NULL
                        ORDER BY MAX(COALESCE(history.lastPlayed, 0), COALESCE(song.playedAt, 0)) DESC, song.id
                        LIMIT ? OFFSET ?
                        """, arguments: [limit, offset])
            }
        }
        if route == .downloaded {
            // Only inspect indexed candidates, in bounded batches, never scan the filesystem.
            var result: [SongRecord] = []
            var cursor = 0
            var skipped = 0
            while result.count < limit {
                let batch = try db.read { db in
                    try SongRecord.fetchAll(
                        db,
                        sql: """
                            SELECT song.* FROM song JOIN cacheMeta ON cacheMeta.id = song.id
                            WHERE cacheMeta.type = 'audio' ORDER BY song.title, song.id LIMIT 100 OFFSET ?
                            """, arguments: [cursor])
                }
                if batch.isEmpty { break }
                cursor += batch.count
                for song in batch where isDownloaded(song.id) {
                    if skipped < offset { skipped += 1 } else { result.append(song) }
                    if result.count == limit { break }
                }
            }
            return result
        }
        return try db.read { db in
            switch route {
            case .album(let id):
                return try SongRecord.fetchAll(
                    db, sql: "SELECT * FROM song WHERE albumId = ? ORDER BY discNumber, track, id LIMIT ? OFFSET ?",
                    arguments: [id, limit, offset])
            case .favorites:
                return try SongRecord.fetchAll(
                    db, sql: "SELECT * FROM song WHERE starredAt IS NOT NULL ORDER BY title, id LIMIT ? OFFSET ?",
                    arguments: [limit, offset])
            default: return []
            }
        }
    }

    private func playlistSongs(_ id: String) throws -> [SongRecord] {
        guard let detail = try PlaylistRepository(db: db).getDetailById(id),
            let data = detail.entriesJson.data(using: .utf8),
            let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        let ids = entries.compactMap { $0["id"] as? String }
        // Preserve duplicate occurrences and order; resolve in chunks below SQLite's parameter limit.
        var byId: [String: SongRecord] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            for song in try SongRepository(db: db).getByIds(ids: slice) { byId[song.id] = song }
        }
        return ids.compactMap { byId[$0] }
    }

    func isDownloaded(_ id: String) -> Bool {
        cacheDirectories.contains { directory in
            let metaURL = directory.appendingPathComponent("\(AudioCacheUtils.cacheId(for: id)).json")
            guard let data = try? Data(contentsOf: metaURL),
                let metadata = try? JSONDecoder().decode(NativeCachedAudioFileMetadata.self, from: data),
                metadata.songId == id,
                URL(fileURLWithPath: metadata.fileName).lastPathComponent == metadata.fileName
            else { return false }
            let file = directory.appendingPathComponent(metadata.fileName)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let expected = try? CacheMetaRepository(db: self.db).getByKey("audio:\(id)")?.sizeBytes
            return values?.isRegularFile == true && (expected ?? 0) > 0 && values?.fileSize == expected
        }
    }

    private func sameAccount(_ identity: ServerCredentials) -> Bool {
        guard let current = credentials() else { return false }
        return current.serverUrl == identity.serverUrl && current.username == identity.username
    }

    private func ensurePlaylist(_ id: String) async throws {
        try Task.checkCancellation()
        guard let identity = credentials() else { throw CarPlayError.notLoggedIn }
        let cached = try await read { try PlaylistRepository(db: self.db).getDetailById(id) }
        if cached != nil { return }
        let response = try await http.request(
            baseUrl: identity.serverUrl, path: "getPlaylist.view",
            credentials: identity, extraQuery: ["id": id])
        try Task.checkCancellation()
        guard sameAccount(identity) else { throw CancellationError() }
        guard let playlist = response.data["playlist"] as? [String: Any],
            let name = playlist["name"] as? String
        else { throw CarPlayError.unavailable }
        let entries = playlist["entry"] as? [[String: Any]] ?? []
        let json = String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
        let detail = PlaylistDetailRecord(
            id: id, name: name, comment: playlist["comment"] as? String,
            songCount: entries.count, duration: playlist["duration"] as? Int ?? 0,
            isPublic: playlist["public"] as? Bool ?? false, owner: playlist["owner"] as? String,
            created: playlist["created"] as? String, changed: playlist["changed"] as? String,
            coverArt: playlist["coverArt"] as? String, starred: nil, starredAt: nil, entriesJson: json)
        try await read {
            guard self.sameAccount(identity) else { throw CancellationError() }
            let records = try entries.map { entry -> SongRecord in
                var values = entry
                values["duration"] = entry["duration"] as? Int ?? 0
                return try JSONDecoder().decode(SongRecord.self, from: JSONSerialization.data(withJSONObject: values))
            }
            try SongRepository(db: self.db).bulkUpsert(records)
            try PlaylistRepository(db: self.db).upsertDetail(detail)
        }
    }

    static func recordCached(songId: String, size: Int, database: DatabasePool = DatabaseManager.shared.dbPool) {
        guard size > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            let repo = CacheMetaRepository(db: database)
            let now = Int(Date().timeIntervalSince1970 * 1000)
            if var existing = try? repo.getByKey("audio:\(songId)") {
                existing.sizeBytes = size
                existing.lastAccessedAt = now
                try? repo.upsert(existing)
            } else {
                try? repo.upsert(
                    CacheMetaRecord(
                        key: "audio:\(songId)", id: songId, type: "audio",
                        source: "buffering", triggersJson: nil, coverSize: nil, sizeBytes: size,
                        cachedAt: now, lastAccessedAt: now, removedFromServer: nil))
            }
            NotificationCenter.default.post(name: .aonsokuNativeLibraryChanged, object: nil)
        }
    }

    static func recordPlayed(songId: String, database: DatabasePool = DatabaseManager.shared.dbPool) {
        let db = database
        DispatchQueue.global(qos: .utility).async {
            try? db.write { db in
                try db.execute(
                    sql: "UPDATE song SET playedAt = ? WHERE id = ?",
                    arguments: [Int(Date().timeIntervalSince1970 * 1000), songId])
            }
            NotificationCenter.default.post(name: .aonsokuNativeLibraryChanged, object: nil)
        }
    }
}
