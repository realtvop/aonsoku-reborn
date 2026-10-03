import Foundation

public final class LibraryService: @unchecked Sendable {
    public typealias EventHandler = @Sendable (LibraryEvent) -> Void

    private let dbManager: DatabaseManager
    private let syncEngine: SyncEngine
    private let syncScheduler: SyncScheduler
    private let imageCache: ImageCacheManager
    private let listenerQueue = DispatchQueue(
        label: "com.aonsoku.LibraryService.listeners"
    )
    private var listeners: [UUID: EventHandler] = [:]
    private var initialized = false

    init(
        dbManager: DatabaseManager = .shared,
        httpClient: SubsonicHTTPClient = SubsonicHTTPClient()
    ) {
        self.dbManager = dbManager
        syncEngine = SyncEngine(db: dbManager.dbPool, httpClient: httpClient)
        syncScheduler = SyncScheduler(syncEngine: syncEngine)
        imageCache = ImageCacheManager(db: dbManager.dbPool)
        syncEngine.onSyncStateChanged = { [weak self] raw in
            guard let self else { return }
            self.emit(.syncStateChanged(LibrarySyncState(
                phase: raw["phase"] as? String ?? "idle",
                tier: raw["tier"] as? String,
                isSyncing: self.syncEngine.isSyncing,
                processedItems: raw["processedItems"] as? Int ?? 0,
                totalItems: raw["totalItems"] as? Int ?? 0
            )))
        }
        syncEngine.onDataChanged = { [weak self] tables in
            self?.emit(.dataChanged(tables: tables))
        }
    }

    @discardableResult
    public func initialize(startAutomaticSync: Bool = true) -> LibraryInitialization {
        let hasData = (try? SyncStateRepository(
            db: dbManager.dbPool
        ).getFullSyncTimestamp()) != nil
        if !initialized {
            initialized = true
            syncScheduler.startForegroundSchedule()
            if startAutomaticSync {
                hasData ? syncEngine.syncIncremental() : syncEngine.syncAll()
            }
        }
        return LibraryInitialization(ready: true, needsMigration: !hasData)
    }

    @discardableResult
    public func subscribe(_ handler: @escaping EventHandler) -> UUID {
        let token = UUID()
        listenerQueue.sync { listeners[token] = handler }
        return token
    }

    public func unsubscribe(_ token: UUID) {
        listenerQueue.sync { listeners.removeValue(forKey: token) }
    }

    public func syncAll() { syncEngine.syncAll() }
    public func syncIncremental() { syncEngine.syncIncremental() }
    public func cancelSync() { syncEngine.cancel() }
    public var isSyncing: Bool { syncEngine.isSyncing }

    public func artists(
        limit: Int = 100,
        offset: Int = 0,
        filter: LibraryArtistFilter = LibraryArtistFilter()
    ) throws -> LibraryPage<LibraryArtist> {
        let result = try ArtistRepository(db: dbManager.dbPool).getAll(
            limit: limit,
            offset: offset,
            filter: ArtistQueryFilter(
                search: filter.search,
                starredOnly: filter.starredOnly,
                sortBy: filter.sortBy,
                sortOrder: filter.sortOrder
            )
        )
        return LibraryPage(
            items: result.items.map(\.libraryValue),
            total: result.total,
            hasMore: offset + limit < result.total
        )
    }

    public func artist(id: String) throws -> LibraryArtist? {
        try ArtistRepository(db: dbManager.dbPool).getById(id)?.libraryValue
    }

    public func albums(
        limit: Int = 100,
        offset: Int = 0,
        filter: LibraryAlbumFilter = LibraryAlbumFilter()
    ) throws -> LibraryPage<LibraryAlbum> {
        let result = try AlbumRepository(db: dbManager.dbPool).getAll(
            limit: limit,
            offset: offset,
            filter: AlbumQueryFilter(
                search: filter.search,
                artistId: filter.artistId,
                genre: filter.genre,
                fromYear: filter.fromYear,
                toYear: filter.toYear,
                starredOnly: filter.starredOnly,
                sortBy: filter.sortBy,
                sortOrder: filter.sortOrder
            )
        )
        return LibraryPage(
            items: result.items.map(\.libraryValue),
            total: result.total,
            hasMore: offset + limit < result.total
        )
    }

    public func album(id: String) throws -> LibraryAlbumDetail? {
        try AlbumRepository(db: dbManager.dbPool).getWithSongs(id).map {
            LibraryAlbumDetail(
                album: $0.album.libraryValue,
                songs: $0.songs.map(\.libraryValue)
            )
        }
    }

    public func songs(
        limit: Int = 100,
        offset: Int = 0,
        filter: LibrarySongFilter = LibrarySongFilter()
    ) throws -> LibraryPage<LibrarySong> {
        let result = try SongRepository(db: dbManager.dbPool).getAll(
            limit: limit,
            offset: offset,
            filter: SongQueryFilter(
                search: filter.search,
                albumId: filter.albumId,
                artistId: filter.artistId,
                genre: filter.genre,
                starredOnly: filter.starredOnly,
                sortBy: filter.sortBy,
                sortOrder: filter.sortOrder
            )
        )
        return LibraryPage(
            items: result.items.map(\.libraryValue),
            total: result.total,
            hasMore: offset + limit < result.total
        )
    }

    public func songs(ids: [String]) throws -> [LibrarySong] {
        let records = try SongRepository(db: dbManager.dbPool).getByIds(ids: ids)
        let byId = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ids.compactMap { byId[$0]?.libraryValue }
    }

    public func playlists(
        limit: Int = 100,
        offset: Int = 0
    ) throws -> LibraryPage<LibraryPlaylist> {
        let result = try PlaylistRepository(db: dbManager.dbPool).getAll(
            limit: limit,
            offset: offset
        )
        return LibraryPage(
            items: result.items.map(\.libraryValue),
            total: result.total,
            hasMore: offset + limit < result.total
        )
    }

    public func playlist(id: String) throws -> LibraryPlaylistDetail? {
        try PlaylistRepository(db: dbManager.dbPool).getDetailById(id).map {
            LibraryPlaylistDetail(
                playlist: $0.libraryPlaylist,
                entriesJSON: $0.entriesJson
            )
        }
    }

    public func genres() throws -> [LibraryGenre] {
        try GenreRepository(db: dbManager.dbPool).getAll().map(\.libraryValue)
    }

    public func search(
        query: String,
        artistCount: Int = 20,
        albumCount: Int = 20,
        songCount: Int = 20
    ) throws -> LibrarySearchResults {
        guard !query.isEmpty else {
            return LibrarySearchResults(artists: [], albums: [], songs: [])
        }
        return LibrarySearchResults(
            artists: try artists(
                limit: artistCount,
                filter: LibraryArtistFilter(search: query)
            ).items,
            albums: try albums(
                limit: albumCount,
                filter: LibraryAlbumFilter(search: query)
            ).items,
            songs: try songs(
                limit: songCount,
                filter: LibrarySongFilter(search: query)
            ).items
        )
    }

    public func lyrics(songId: String) throws -> LibraryLyrics? {
        let repository = LyricsRepository(db: dbManager.dbPool)
        let result = try repository.getBySongId(songId)
        if result != nil { try? repository.updateAccessTime(songId: songId) }
        return result?.libraryValue
    }

    public func storeLyrics(songId: String, content: String, synced: Bool) throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        try LyricsRepository(db: dbManager.dbPool).upsert(LyricsRecord(
            songId: songId,
            content: content,
            synced: synced,
            cachedAt: now,
            lastAccessedAt: now
        ))
    }

    public func cacheStats() throws -> LibraryCacheStats {
        let stats = try CacheMetaRepository(db: dbManager.dbPool).getStats()
        return LibraryCacheStats(
            totalItems: stats.totalItems,
            totalSizeBytes: stats.totalSizeBytes,
            audioCount: stats.audioCount,
            coverCount: stats.coverCount
        )
    }

    public func availability() -> LibraryAvailability {
        let timestamp = try? SyncStateRepository(
            db: dbManager.dbPool
        ).getFullSyncTimestamp()
        return LibraryAvailability(
            available: timestamp != nil,
            lastSyncedAt: timestamp
        )
    }

    public func storeCover(
        id: String,
        data: Data,
        contentType: String,
        size: String
    ) throws -> LibraryCachedImage {
        let url = try imageCache.storeCoverImage(
            coverArtId: id,
            data: data,
            contentType: contentType,
            coverSize: size
        )
        return cachedImage(
            id: id,
            url: url,
            contentType: contentType,
            requestedSize: size
        )
    }

    public func resolveCover(id: String, requestedSize: String) -> LibraryCachedImage? {
        imageCache.resolveCoverImage(coverArtId: id).map {
            cachedImage(id: id, url: $0, contentType: nil, requestedSize: requestedSize)
        }
    }

    public func coverSize(id: String) -> LibraryCoverSize? {
        imageCache.getCoverImageSize(coverArtId: id).map {
            LibraryCoverSize(sizeBytes: $0.sizeBytes, coverSize: $0.coverSize)
        }
    }

    public func deleteCover(id: String) throws -> Bool {
        try imageCache.deleteCoverImage(coverArtId: id)
    }

    public func clearCovers() throws -> Int {
        try imageCache.clearCoverImages()
    }

    public func downloadCover(id: String, size: String) async throws -> LibraryCachedImage {
        let url = try await imageCache.downloadCoverImage(coverArtId: id, size: size)
        return cachedImage(id: id, url: url, contentType: nil, requestedSize: size)
    }

    public func downloadAvatar(username: String, size: String) async throws -> LibraryCachedImage {
        let url = try await imageCache.downloadAvatar(username: username, size: size)
        return cachedImage(id: username, url: url, contentType: nil, requestedSize: size)
    }

    private func cachedImage(
        id: String,
        url: URL,
        contentType: String?,
        requestedSize: String
    ) -> LibraryCachedImage {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return LibraryCachedImage(
            id: id,
            uri: url.absoluteString,
            contentType: contentType,
            sizeBytes: (attributes?[.size] as? NSNumber)?.intValue,
            requestedSize: requestedSize
        )
    }

    private func emit(_ event: LibraryEvent) {
        let handlers = listenerQueue.sync { Array(listeners.values) }
        for handler in handlers { handler(event) }
    }
}

private extension ArtistRecord {
    var libraryValue: LibraryArtist {
        LibraryArtist(
            id: id,
            name: name,
            albumCount: albumCount,
            coverArt: coverArt,
            artistImageUrl: artistImageUrl,
            starred: starred,
            starredAt: starredAt,
            musicBrainzId: musicBrainzId,
            sortName: sortName
        )
    }
}

private extension AlbumRecord {
    var libraryValue: LibraryAlbum {
        LibraryAlbum(
            id: id,
            name: name,
            artist: artist,
            artistId: artistId,
            coverArt: coverArt,
            songCount: songCount,
            duration: duration,
            year: year,
            genre: genre,
            created: created,
            played: played,
            playCount: playCount,
            starred: starred,
            starredAt: starredAt
        )
    }
}

private extension SongRecord {
    var libraryValue: LibrarySong {
        LibrarySong(
            id: id,
            parent: parent,
            title: title,
            album: album,
            artist: artist,
            track: track,
            year: year,
            genre: genre,
            coverArt: coverArt,
            size: size,
            contentType: contentType,
            suffix: suffix,
            duration: duration,
            bitRate: bitRate,
            path: path,
            playCount: playCount,
            discNumber: discNumber,
            created: created,
            albumId: albumId,
            artistId: artistId,
            played: played,
            starred: starred,
            starredAt: starredAt,
            playedAt: playedAt,
            bpm: bpm,
            comment: comment,
            sortName: sortName,
            mediaType: mediaType,
            musicBrainzId: musicBrainzId,
            genresJSON: genresJson,
            replayGainJSON: replayGainJson
        )
    }
}

private extension PlaylistRecord {
    var libraryValue: LibraryPlaylist {
        LibraryPlaylist(
            id: id,
            name: name,
            comment: comment,
            songCount: songCount,
            duration: duration,
            isPublic: isPublic,
            owner: owner,
            created: created,
            changed: changed,
            coverArt: coverArt,
            starred: starred,
            starredAt: starredAt
        )
    }
}

private extension PlaylistDetailRecord {
    var libraryPlaylist: LibraryPlaylist {
        LibraryPlaylist(
            id: id,
            name: name,
            comment: comment,
            songCount: songCount,
            duration: duration,
            isPublic: isPublic,
            owner: owner,
            created: created,
            changed: changed,
            coverArt: coverArt,
            starred: starred,
            starredAt: starredAt
        )
    }
}

private extension GenreRecord {
    var libraryValue: LibraryGenre {
        LibraryGenre(value: value, songCount: songCount, albumCount: albumCount)
    }
}

private extension LyricsRecord {
    var libraryValue: LibraryLyrics {
        LibraryLyrics(
            songId: songId,
            content: content,
            synced: synced,
            cachedAt: cachedAt,
            lastAccessedAt: lastAccessedAt
        )
    }
}
