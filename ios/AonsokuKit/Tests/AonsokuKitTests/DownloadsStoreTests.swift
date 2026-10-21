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
        let file = try fixture.audio.storeAudioFile(
            songId: "event",
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        fixture.store.start()
        fixture.store.handleAudioEvent(.downloadProgress(songId: "event", loaded: 5, total: 10))
        XCTAssertEqual(fixture.store.activeDownloads.overallProgress, 0.5)
        fixture.store.handleAudioEvent(.downloadCompleted(songId: "event", file: file))
        XCTAssertEqual(fixture.store.state(ofSong: "event"), .cached(source: .explicit, removedFromServer: false))

        let stream = try fixture.audio.storeAudioFile(
            songId: "stream",
            data: makeSilentWAVData(),
            contentType: "audio/wav"
        )
        fixture.store.handleAudioEvent(.streamCacheCompleted(songId: "stream", file: stream))
        XCTAssertEqual(fixture.store.state(ofSong: "stream"), .cached(source: .lru, removedFromServer: false))

        fixture.store.handleAudioEvent(.downloadFailed(songId: "bad", message: "failed"))
        XCTAssertEqual(fixture.store.toasts?.current?.message, .text("failed"))
        _ = try? fixture.audio.deleteAudioFile(songId: "event")
        _ = try? fixture.audio.deleteAudioFile(songId: "stream")
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
            now: { Date(timeIntervalSince1970: 10) }
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
