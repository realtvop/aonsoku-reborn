import XCTest
@testable import AonsokuKit

@MainActor
final class DownloadsStoreTests: XCTestCase {
    func testLoadsStateAndUpgradesExistingFileToExplicit() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("upgrade")
        let file = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        try fixture.library.upsertCacheMetadata(fixture.row(
            song.id,
            source: .lru,
            size: Int(file.sizeBytes ?? 0)
        ))

        fixture.store.start()
        XCTAssertEqual(fixture.store.state(ofSong: song.id), .cached(source: .lru, removedFromServer: false))
        await fixture.store.download(songs: [song])
        XCTAssertEqual(fixture.store.state(ofSong: song.id), .cached(source: .explicit, removedFromServer: false))
        let explicitIds = await fixture.store.items(filter: .explicit).map(\.itemId)
        XCTAssertEqual(explicitIds, [song.id])
        _ = try? fixture.audio.deleteAudioFile(songId: song.id)
    }

    func testProgressCompletionFailureAndStreamCache() async throws {
        let fixture = try DownloadsFixture()
        let eventSong = fixture.song("event")
        let file = try fixture.audio.storeAudioFile(
            songId: eventSong.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        fixture.store.start()
        await fixture.store.download(songs: [eventSong])
        let eventRequestId = try XCTUnwrap(fixture.commands.requestId(for: eventSong.id))
        fixture.store.handleAudioEvent(.downloadProgress(
            songId: "event",
            requestId: eventRequestId,
            loaded: 5,
            total: 10
        ))
        XCTAssertEqual(fixture.store.activeDownloads.overallProgress, 0.5)
        fixture.store.handleAudioEvent(.downloadCompleted(
            songId: "event",
            requestId: eventRequestId,
            file: file
        ))
        XCTAssertEqual(fixture.store.state(ofSong: "event"), .cached(source: .explicit, removedFromServer: false))

        let stream = try fixture.audio.storeAudioFile(
            songId: "stream",
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        fixture.store.handleAudioEvent(.streamCacheCompleted(songId: "stream", file: stream))
        XCTAssertEqual(fixture.store.state(ofSong: "stream"), .cached(source: .lru, removedFromServer: false))

        let bad = fixture.song("bad")
        await fixture.store.download(songs: [bad])
        fixture.store.handleAudioEvent(.downloadFailed(
            songId: bad.id,
            requestId: try XCTUnwrap(fixture.commands.requestId(for: bad.id)),
            message: "failed"
        ))
        XCTAssertEqual(fixture.store.toasts?.current?.message, .text("failed"))
        _ = try? fixture.audio.deleteAudioFile(songId: "event")
        _ = try? fixture.audio.deleteAudioFile(songId: "stream")
    }

    func testRemovingPendingSongCancelsAndRejectsLateCompletion() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("remove-pending")
        fixture.store.start()
        await fixture.store.download(songs: [song])
        let requestId = try XCTUnwrap(fixture.commands.requestId(for: song.id))
        XCTAssertTrue(fixture.store.state(ofSong: song.id).isDownloading)

        await fixture.store.remove(songIds: [song.id])

        XCTAssertEqual(fixture.commands.cancelled, [song.id])
        XCTAssertEqual(fixture.store.state(ofSong: song.id), .notCached)
        let file = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        fixture.store.handleAudioEvent(.downloadCompleted(
            songId: song.id,
            requestId: requestId,
            file: file
        ))
        XCTAssertEqual(fixture.store.state(ofSong: song.id), .notCached)
        XCTAssertNil(try fixture.audio.resolveAudioFile(songId: song.id))
    }

    func testCancelThenRedownloadRejectsOnlyTheOldRequest() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("redownload")
        fixture.store.start()
        await fixture.store.download(songs: [song])
        let oldRequestId = try XCTUnwrap(fixture.commands.requestId(for: song.id))
        await fixture.store.remove(songIds: [song.id])

        await fixture.store.download(songs: [song])
        let newRequestId = try XCTUnwrap(fixture.commands.requestId(for: song.id))
        XCTAssertNotEqual(oldRequestId, newRequestId)
        let file = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )

        fixture.store.handleAudioEvent(.downloadCompleted(
            songId: song.id,
            requestId: oldRequestId,
            file: file
        ))
        XCTAssertTrue(fixture.store.state(ofSong: song.id).isDownloading)
        fixture.store.handleAudioEvent(.downloadCompleted(
            songId: song.id,
            requestId: newRequestId,
            file: file
        ))
        XCTAssertEqual(
            fixture.store.state(ofSong: song.id),
            .cached(source: .explicit, removedFromServer: false)
        )
        _ = try? fixture.audio.deleteAudioFile(songId: song.id)
    }

    func testRemovingPendingCollectionsCancelsTheirSongs() async throws {
        let fixture = try DownloadsFixture()
        let albumSong = fixture.song("album-pending")
        let playlistSong = fixture.song("playlist-pending")
        fixture.api.albumHandler = { _ in
            AlbumDetail(album: Album(id: "album", name: "Album"), songs: [albumSong])
        }
        fixture.api.playlistHandler = { _ in
            PlaylistDetail(
                playlist: Playlist(id: "playlist", name: "Playlist"),
                songs: [playlistSong]
            )
        }
        fixture.store.start()

        await fixture.store.download(albumId: "album")
        await fixture.store.remove(albumId: "album")
        await fixture.store.download(playlistId: "playlist")
        await fixture.store.remove(playlistId: "playlist")

        XCTAssertEqual(Set(fixture.commands.cancelled.compactMap { $0 }), [
            albumSong.id,
            playlistSong.id,
        ])
        XCTAssertEqual(fixture.store.state(ofAlbum: "album"), .notCached)
        XCTAssertEqual(fixture.store.state(ofPlaylist: "playlist"), .notCached)
    }

    func testCollectionMarkerWithoutKnownSongsIsNotReportedAsCached() throws {
        let fixture = try DownloadsFixture()
        try fixture.library.upsertCacheMetadata(CacheMetaRecord(
            key: "album:unknown",
            id: "unknown",
            type: CachedItemType.album.rawValue,
            source: CacheSource.explicit.rawValue,
            triggersJson: nil,
            coverSize: nil,
            sizeBytes: 0,
            cachedAt: 1,
            lastAccessedAt: 1,
            removedFromServer: false
        ))

        fixture.store.start()

        XCTAssertEqual(fixture.store.state(ofAlbum: "unknown"), .notCached)
    }

    func testPersistedCollectionSongsSupportOfflineRemoval() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("offline-album-song")
        let file = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        try fixture.library.upsertCacheMetadata(fixture.row(
            song.id,
            source: .explicit,
            size: Int(file.sizeBytes ?? 0)
        ))
        try fixture.library.upsertCacheMetadata(CacheMetaRecord(
            key: "album:offline",
            id: "offline",
            type: CachedItemType.album.rawValue,
            source: CacheSource.explicit.rawValue,
            triggersJson: #"["offline-album-song"]"#,
            coverSize: nil,
            sizeBytes: 0,
            cachedAt: 1,
            lastAccessedAt: 1,
            removedFromServer: false
        ))

        fixture.store.start()
        XCTAssertEqual(fixture.store.state(ofAlbum: "offline"), .cached)

        await fixture.store.remove(albumId: "offline")

        XCTAssertEqual(fixture.store.state(ofAlbum: "offline"), .notCached)
        XCTAssertEqual(fixture.store.state(ofSong: song.id), .notCached)
        XCTAssertNil(try fixture.audio.resolveAudioFile(songId: song.id))
    }

    func testClearAndCancelAllCancelPendingDownloads() async throws {
        let fixture = try DownloadsFixture()
        let explicit = fixture.song("clear-explicit")
        let remaining = fixture.song("cancel-all")
        fixture.store.start()
        await fixture.store.download(songs: [explicit])

        await fixture.store.clear(source: .explicit)
        await fixture.store.download(songs: [remaining])
        fixture.store.cancelAll()

        XCTAssertEqual(fixture.commands.cancelled, [explicit.id, nil])
        XCTAssertEqual(fixture.store.activeDownloads.activeCount, 0)
        XCTAssertEqual(fixture.store.state(ofSong: explicit.id), .notCached)
        XCTAssertEqual(fixture.store.state(ofSong: remaining.id), .notCached)
    }

    func testSharedAlbumAndPlaylistRemovalKeepsThenDeletesSong() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("shared")
        let album = Album(id: "album", name: "Album")
        let playlist = Playlist(id: "playlist", name: "Playlist")
        fixture.api.albumHandler = { _ in AlbumDetail(album: album, songs: [song]) }
        fixture.api.playlistHandler = { _ in PlaylistDetail(playlist: playlist, songs: [song]) }
        let file = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        try fixture.library.upsertCacheMetadata(fixture.row(
            song.id,
            source: .lru,
            size: Int(file.sizeBytes ?? 0)
        ))
        fixture.store.start()

        await fixture.store.download(albumId: album.id)
        await fixture.store.download(playlistId: playlist.id)
        XCTAssertEqual(fixture.store.state(ofAlbum: album.id), .cached)
        XCTAssertEqual(fixture.store.state(ofPlaylist: playlist.id), .cached)
        await fixture.store.remove(albumId: album.id)
        XCTAssertTrue(fixture.store.state(ofSong: song.id).isCached)
        await fixture.store.remove(playlistId: playlist.id)
        XCTAssertEqual(fixture.store.state(ofSong: song.id), .notCached)
    }

    func testUsageFiltersAndLRUEviction() async throws {
        let fixture = try DownloadsFixture()
        fixture.settings.update { $0.cache.lruQuota = 10 }
        for (id, size, accessed) in [("old", 8, 1), ("new", 8, 2)] {
            _ = try fixture.audio.storeAudioFile(
                songId: id,
                data: makeSilentWAVData(),
                contentType: "audio/wav"
            )
            try fixture.library.upsertCacheMetadata(fixture.row(
                id,
                source: .lru,
                size: size,
                accessed: accessed
            ))
        }
        fixture.store.start()
        await fixture.store.refreshUsage()
        XCTAssertEqual(fixture.store.usage.lru.sizeBytes, 16)
        let lruCount = await fixture.store.items(filter: .lru).count
        XCTAssertEqual(lruCount, 2)
        await fixture.store.enforceQuotas()
        XCTAssertEqual(fixture.store.state(ofSong: "old"), .notCached)
        XCTAssertTrue(fixture.store.state(ofSong: "new").isCached)
        _ = try? fixture.audio.deleteAudioFile(songId: "new")
    }

    func testSmartFavoriteUpgradesAndCleansUp() async throws {
        let fixture = try DownloadsFixture()
        var record = makeSongRecord("favorite")
        record.starred = "2026-01-01T00:00:00Z"
        record.starredAt = 1
        try SongRepository(db: fixture.database.manager.dbPool).upsert(record)
        _ = try fixture.audio.storeAudioFile(
            songId: record.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        try fixture.library.upsertCacheMetadata(fixture.row(
            record.id,
            source: .lru,
            size: 8
        ))
        fixture.settings.update { $0.cache.smartRules.enabled = true }
        fixture.store.start()

        await fixture.store.applySmartRules()
        XCTAssertEqual(
            fixture.store.state(ofSong: record.id),
            .cached(source: .smart, removedFromServer: false)
        )
        try fixture.library.setStarred(songIds: [record.id], starred: false)
        await fixture.store.applySmartRules()
        XCTAssertEqual(fixture.store.state(ofSong: record.id), .notCached)
    }

    func testSmartRulesSkipMeteredNetwork() async throws {
        let fixture = try DownloadsFixture(connectivity: FixedConnectivity(isMetered: true))
        var record = makeSongRecord("metered")
        record.starred = "2026-01-01T00:00:00Z"
        record.starredAt = 1
        try SongRepository(db: fixture.database.manager.dbPool).upsert(record)
        _ = try fixture.audio.storeAudioFile(
            songId: record.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        try fixture.library.upsertCacheMetadata(fixture.row(
            record.id,
            source: .lru,
            size: 8
        ))
        fixture.settings.update { $0.cache.smartRules.enabled = true }
        fixture.store.start()

        await fixture.store.applySmartRules()
        XCTAssertEqual(
            fixture.store.state(ofSong: record.id),
            .cached(source: .lru, removedFromServer: false)
        )
        _ = try? fixture.audio.deleteAudioFile(songId: record.id)
    }

    func testDisablingSmartRulesRemovesCachedAndPendingSmartDownloads() async throws {
        let fixture = try DownloadsFixture()
        var cached = makeSongRecord("cached-smart")
        cached.starred = "2026-01-01T00:00:00Z"
        cached.starredAt = 1
        var pending = makeSongRecord("pending-smart")
        pending.starred = "2026-01-01T00:00:00Z"
        pending.starredAt = 1
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert([
            cached,
            pending,
        ])
        _ = try fixture.audio.storeAudioFile(
            songId: cached.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        try fixture.library.upsertCacheMetadata(fixture.row(
            cached.id,
            source: .smart,
            size: 8
        ))
        fixture.settings.update {
            $0.cache.smartRules.enabled = true
            $0.cache.smartRules.favoriteSongs = true
        }
        fixture.store.start()

        await fixture.store.applySmartRules()
        XCTAssertEqual(fixture.commands.started.map(\.songId), [pending.id])

        fixture.settings.update { $0.cache.smartRules.enabled = false }
        await fixture.store.applySmartRules()

        XCTAssertEqual(fixture.store.state(ofSong: cached.id), .notCached)
        XCTAssertEqual(fixture.store.state(ofSong: pending.id), .notCached)
        XCTAssertEqual(fixture.commands.cancelled, [pending.id])
    }

    func testSmartFavoritePlaylistFetchesMissingDetailFromServer() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("playlist-song")
        let playlist = Playlist(
            id: "favorite-playlist",
            name: "Favorite Playlist",
            songCount: 1,
            starred: Date(timeIntervalSince1970: 1)
        )
        try PlaylistRepository(db: fixture.database.manager.dbPool).upsert(
            PlaylistRecord(
                id: playlist.id,
                name: playlist.name,
                comment: nil,
                songCount: playlist.songCount,
                duration: 0,
                isPublic: false,
                owner: nil,
                created: nil,
                changed: nil,
                coverArt: nil,
                starred: "1970-01-01T00:00:01Z",
                starredAt: 1
            )
        )
        let requestedPlaylistIds = LockedTestBox<[String]>([])
        fixture.api.playlistHandler = { id in
            requestedPlaylistIds.update { $0.append(id) }
            return PlaylistDetail(playlist: playlist, songs: [song])
        }
        fixture.api.songHandler = { id in
            XCTAssertEqual(id, song.id)
            return song
        }
        fixture.settings.update {
            $0.cache.smartRules.enabled = true
            $0.cache.smartRules.favoriteSongs = false
            $0.cache.smartRules.favoritePlaylists = true
        }
        fixture.store.start()

        await fixture.store.applySmartRules()

        XCTAssertEqual(requestedPlaylistIds.read { $0 }, [playlist.id])
        XCTAssertEqual(fixture.commands.started.map(\.songId), [song.id])
    }

    func testSmartPlaylistFailurePreservesExistingPlaylistCache() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("existing-playlist-song")
        try SongRepository(db: fixture.database.manager.dbPool).upsert(
            makeSongRecord(song.id)
        )
        try PlaylistRepository(db: fixture.database.manager.dbPool).upsert(
            PlaylistRecord(
                id: "unavailable-playlist",
                name: "Unavailable Playlist",
                comment: nil,
                songCount: 1,
                duration: 0,
                isPublic: false,
                owner: nil,
                created: nil,
                changed: nil,
                coverArt: nil,
                starred: "1970-01-01T00:00:01Z",
                starredAt: 1
            )
        )
        _ = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        var row = fixture.row(song.id, source: .smart, size: 8)
        row.triggersJson = #"["playlist"]"#
        try fixture.library.upsertCacheMetadata(row)
        fixture.settings.update {
            $0.cache.smartRules.enabled = true
            $0.cache.smartRules.favoriteSongs = false
            $0.cache.smartRules.favoritePlaylists = true
        }
        fixture.store.start()

        await fixture.store.applySmartRules()

        XCTAssertEqual(
            fixture.store.state(ofSong: song.id),
            .cached(source: .smart, removedFromServer: false)
        )
    }

    func testLibrarySyncReloadsRemovedFromServerState() async throws {
        let fixture = try DownloadsFixture()
        let song = fixture.song("removed")
        _ = try fixture.audio.storeAudioFile(
            songId: song.id,
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        var row = fixture.row(song.id, source: .explicit, size: 8)
        try fixture.library.upsertCacheMetadata(row)
        fixture.store.start()
        XCTAssertEqual(
            fixture.store.state(ofSong: song.id),
            .cached(source: .explicit, removedFromServer: false)
        )

        row.removedFromServer = true
        try fixture.library.upsertCacheMetadata(row)
        fixture.store.reloadAfterLibrarySync()

        XCTAssertEqual(
            fixture.store.state(ofSong: song.id),
            .cached(source: .explicit, removedFromServer: true)
        )
    }
}

@MainActor
private final class DownloadsFixture {
    let database: TemporaryDatabase
    let library: LibraryService
    let audio: AudioService
    let api = FakeSubsonicAPI()
    let preferences: PreferencesService
    let settings: SettingsStore
    let repository: LibraryRepository
    let toasts = ToastCenter()
    let commands = DownloadCommandSpy()
    let store: DownloadsStore

    init(connectivity: any Connectivity = FixedConnectivity()) throws {
        database = try TemporaryDatabase()
        library = LibraryService(
            dbManager: database.manager,
            credentialsProvider: { nil }
        )
        audio = AudioService(databaseManager: database.manager)
        preferences = PreferencesService(db: database.manager.dbPool)
        settings = SettingsStore(preferences: preferences)
        repository = LibraryRepository(
            api: api,
            library: library,
            connectivity: connectivity
        )
        store = DownloadsStore(
            audio: audio,
            library: library,
            repository: repository,
            settings: settings,
            now: { Date(timeIntervalSince1970: 10) },
            commands: commands.operations
        )
        store.toasts = toasts
    }

    func song(_ id: String) -> Song {
        Song(id: id, title: "Song \(id)", album: "Album", artist: "Artist")
    }

    func row(
        _ id: String,
        source: CacheSource,
        size: Int,
        accessed: Int = 1
    ) -> CacheMetaRecord {
        CacheMetaRecord(
            key: "audio:\(id)",
            id: id,
            type: "audio",
            source: source.rawValue,
            triggersJson: nil,
            coverSize: nil,
            sizeBytes: size,
            cachedAt: accessed,
            lastAccessedAt: accessed,
            removedFromServer: false
        )
    }
}

@MainActor
private final class DownloadCommandSpy {
    var started: [(songId: String, requestId: String)] = []
    var cancelled: [String?] = []

    func requestId(for songId: String) -> String? {
        started.last(where: { $0.songId == songId })?.requestId
    }

    var operations: DownloadCommands {
        DownloadCommands(
            start: { [weak self] id, requestId, _, _ in
                self?.started.append((id, requestId))
            },
            cancel: { [weak self] id in self?.cancelled.append(id) }
        )
    }
}
