import XCTest
@testable import AonsokuKit

final class LibraryEditTests: XCTestCase {
    func testStarredIdsSetStarredAndEventsCoverEveryTable() throws {
        let database = try TemporaryDatabase()
        try SongRepository(db: database.manager.dbPool).upsert(makeCollectionSongRecord("song"))
        try AlbumRepository(db: database.manager.dbPool).upsert(makeCollectionAlbumRecord("album"))
        try ArtistRepository(db: database.manager.dbPool).upsert(makeCollectionArtistRecord("artist"))
        let service = LibraryService(dbManager: database.manager)
        let events = LockedTestBox<[LibraryEvent]>([])
        let token = service.subscribe { event in events.update { $0.append(event) } }
        defer { service.unsubscribe(token) }
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)

        try service.setStarred(
            songIds: ["song"],
            albumIds: ["album"],
            artistIds: ["artist"],
            starred: true,
            at: date
        )

        XCTAssertEqual(try service.starredIds(), LibraryStarredIds(
            songIds: ["song"],
            albumIds: ["album"],
            artistIds: ["artist"]
        ))
        XCTAssertEqual(
            try SongRepository(db: database.manager.dbPool).getById("song")?.starredAt,
            1_800_000_000_125
        )
        XCTAssertEqual(events.read(\.last), .dataChanged(
            tables: ["songs", "albums", "artists"]
        ))

        try service.setStarred(
            songIds: ["song"],
            albumIds: ["album"],
            artistIds: ["artist"],
            starred: false
        )
        XCTAssertEqual(try service.starredIds(), LibraryStarredIds())
    }

    func testRefreshPlaylistFetchesOnceThenRemoveDeletesBothRows() async throws {
        let database = try TemporaryDatabase()
        let calls = LockedTestBox(0)
        let client = StubLibrarySyncHTTPClient { _, path, _, query, _ in
            calls.update { $0 += 1 }
            XCTAssertEqual(path, "getPlaylist.view")
            XCTAssertEqual(query["id"], "playlist")
            return SubsonicResponse(data: [
                "playlist": [
                    "id": "playlist",
                    "name": "Fresh",
                    "comment": "Updated",
                    "songCount": 1,
                    "duration": 123,
                    "public": true,
                    "entry": [["id": "song", "title": "Song"]],
                ],
            ], count: 0)
        }
        let service = makeCollectionLibrary(database: database, httpClient: client)
        let events = LockedTestBox<[LibraryEvent]>([])
        let token = service.subscribe { event in events.update { $0.append(event) } }
        defer { service.unsubscribe(token) }

        try await service.refreshPlaylist(id: "playlist")

        let repository = PlaylistRepository(db: database.manager.dbPool)
        XCTAssertEqual(calls.read { $0 }, 1)
        XCTAssertEqual(try repository.getById("playlist")?.name, "Fresh")
        XCTAssertEqual(try repository.getDetailById("playlist")?.songCount, 1)
        XCTAssertEqual(events.read(\.last), .dataChanged(tables: ["playlists"]))

        try service.removePlaylist(id: "playlist")
        XCTAssertNil(try repository.getById("playlist"))
        XCTAssertNil(try repository.getDetailById("playlist"))
        XCTAssertEqual(events.read(\.last), .dataChanged(tables: ["playlists"]))
    }
}

@MainActor
final class PinnedHomeStoreTests: XCTestCase {
    func testLoadDeduplicatesPersistsAndResolvesByLatestSongPlayback() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        try preferences.setJSON([
            PinnedItem(itemId: "old", kind: .album),
            PinnedItem(itemId: "recent", kind: .album),
            PinnedItem(itemId: "missing", kind: .playlist),
            PinnedItem(itemId: "old", kind: .album),
        ], for: "pinned.v1")
        try AlbumRepository(db: database.manager.dbPool).bulkUpsert([
            makeCollectionAlbumRecord(
                "old",
                name: "Alpha",
                played: "2026-01-01T00:00:00.000Z"
            ),
            makeCollectionAlbumRecord("recent", name: "Beta"),
        ])
        var recentSong = makeCollectionSongRecord("recent-song", albumId: "recent")
        recentSong.played = "2026-03-01T00:00:00.000Z"
        try SongRepository(db: database.manager.dbPool).upsert(recentSong)
        let api = FakeSubsonicAPI()
        let repository = LibraryRepository(
            api: api,
            library: LibraryService(dbManager: database.manager),
            connectivity: FixedConnectivity(isOnline: false)
        )
        let store = PinnedHomeStore(preferences: preferences, repository: repository)

        store.load()
        await store.resolve()

        XCTAssertEqual(store.items.map(\.id), [
            "album:old", "album:recent", "playlist:missing",
        ])
        XCTAssertEqual(store.resolved.map(\.id), ["album:recent", "album:old"])
        XCTAssertTrue(store.isPinned("missing", kind: .playlist))

        store.unpin("recent", kind: .album)
        XCTAssertEqual(store.resolved.map(\.id), ["album:old"])
        store.pin("new", kind: .playlist)
        XCTAssertEqual(store.items.first?.id, "playlist:new")
        let saved = preferences.getJSON("pinned.v1", as: [PinnedItem].self)
        XCTAssertEqual(saved, store.items)
    }
}

@MainActor
final class FavoritesStoreTests: XCTestCase {
    func testLoadPublishesLocalBeforeRemoteAndReplacesIt() async throws {
        let database = try TemporaryDatabase()
        var local = makeCollectionSongRecord("local")
        local.starred = "2026-01-01T00:00:00Z"
        try SongRepository(db: database.manager.dbPool).upsert(local)
        let api = FakeSubsonicAPI()
        let started = expectation(description: "remote favorites started")
        let gate = TestAsyncGate()
        api.starredHandler = {
            started.fulfill()
            await gate.wait()
            return SearchResults(songs: [makeMediaSong("remote")])
        }
        let store = FavoritesStore(
            api: api,
            library: LibraryService(dbManager: database.manager)
        )

        let task = Task { await store.load() }
        await fulfillment(of: [started])
        XCTAssertEqual(store.songIds, ["local"])
        await gate.open()
        await task.value

        XCTAssertEqual(store.songIds, ["remote"])
        XCTAssertEqual(store.revision, 2)
    }

    func testLoadDoesNotOverwriteConcurrentSuccessfulFavorite() async throws {
        let database = try TemporaryDatabase()
        try SongRepository(db: database.manager.dbPool).upsert(
            makeCollectionSongRecord("concurrent")
        )
        let api = FakeSubsonicAPI()
        let started = expectation(description: "remote favorites started")
        let gate = TestAsyncGate()
        api.starredHandler = {
            started.fulfill()
            await gate.wait()
            return SearchResults()
        }
        let library = LibraryService(dbManager: database.manager)
        let store = FavoritesStore(api: api, library: library)

        let load = Task { await store.load() }
        await fulfillment(of: [started])
        await store.setFavorite(.song, id: "concurrent", isFavorite: true)
        XCTAssertTrue(store.songIds.contains("concurrent"))

        await gate.open()
        await load.value

        XCTAssertTrue(store.songIds.contains("concurrent"))
        XCTAssertTrue(try library.starredIds().songIds.contains("concurrent"))
    }

    func testOptimisticSuccessUpdatesLocalAndFailureRollsBackWithToast() async throws {
        let database = try TemporaryDatabase()
        try SongRepository(db: database.manager.dbPool).bulkUpsert([
            makeCollectionSongRecord("ok"),
            makeCollectionSongRecord("fail"),
        ])
        let api = FakeSubsonicAPI()
        api.starHandler = { target in
            if target.songIds == ["fail"] { throw SubsonicAPIError.offline }
        }
        let toasts = ToastCenter()
        let library = LibraryService(dbManager: database.manager)
        let store = FavoritesStore(api: api, library: library, toasts: toasts)

        await store.setFavorite(.song, id: "ok", isFavorite: true)
        XCTAssertTrue(store.songIds.contains("ok"))
        XCTAssertEqual(try library.starredIds().songIds, ["ok"])

        await store.setFavorite(.song, id: "fail", isFavorite: true)
        XCTAssertFalse(store.songIds.contains("fail"))
        XCTAssertEqual(toasts.current?.style, .error)
    }

    func testRapidTogglesSerializeAndSkipIntermediateState() async throws {
        let database = try TemporaryDatabase()
        try SongRepository(db: database.manager.dbPool).upsert(makeCollectionSongRecord("song"))
        let api = FakeSubsonicAPI()
        let started = expectation(description: "first request started")
        let gate = TestAsyncGate()
        let calls = LockedTestBox<[String]>([])
        api.starHandler = { _ in
            calls.update { $0.append("star") }
            started.fulfill()
            await gate.wait()
        }
        api.unstarHandler = { _ in calls.update { $0.append("unstar") } }
        let library = LibraryService(dbManager: database.manager)
        let store = FavoritesStore(api: api, library: library)

        let first = Task { await store.setFavorite(.song, id: "song", isFavorite: true) }
        await fulfillment(of: [started])
        let second = Task { await store.setFavorite(.song, id: "song", isFavorite: false) }
        await Task.yield()
        XCTAssertFalse(store.songIds.contains("song"))
        await gate.open()
        await first.value
        await second.value

        XCTAssertEqual(calls.read { $0 }, ["star", "unstar"])
        XCTAssertFalse(store.songIds.contains("song"))
        XCTAssertFalse(try library.starredIds().songIds.contains("song"))
    }

    func testBatchFavoriteDeduplicatesAndRollsBackTogether() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        let targets = LockedTestBox<[StarTarget]>([])
        api.starHandler = { target in targets.update { $0.append(target) } }
        let store = FavoritesStore(
            api: api,
            library: LibraryService(dbManager: database.manager)
        )

        await store.setFavorite(songIds: ["a", "a", "b"], isFavorite: true)
        XCTAssertEqual(targets.read(\.first)?.songIds, ["a", "b"])
        XCTAssertEqual(store.songIds, ["a", "b"])
    }
}

@MainActor
final class PlaylistsStoreTests: XCTestCase {
    func testLegacyCreateFindsNewestPlaylistAndAppliesFinalFields() async throws {
        let fixture = try CollectionStoreFixture()
        let created = LockedTestBox<[String]>([])
        let updates = LockedTestBox<[(String, PlaylistChanges)]>([])
        fixture.api.createPlaylistHandler = { name, songIds in
            created.update { $0 = [name] + songIds }
            return nil
        }
        fixture.api.playlistsHandler = {
            [
                Playlist(
                    id: "new",
                    name: "Mix",
                    created: Date(timeIntervalSince1970: 200)
                ),
                Playlist(
                    id: "old",
                    name: "Mix",
                    created: Date(timeIntervalSince1970: 100)
                ),
            ]
        }
        fixture.api.updatePlaylistHandler = { id, changes in
            updates.update { $0.append((id, changes)) }
        }
        let store = PlaylistsStore(repository: fixture.repository, api: fixture.api)

        let playlist = try await store.create(
            name: "Mix",
            comment: "Road",
            isPublic: true,
            songIds: ["one"]
        )

        XCTAssertEqual(created.read { $0 }, ["Mix", "one"])
        XCTAssertEqual(playlist?.id, "new")
        XCTAssertEqual(playlist?.comment, "Road")
        XCTAssertEqual(playlist?.isPublic, true)
        XCTAssertEqual(updates.read(\.first)?.0, "new")
        XCTAssertEqual(updates.read(\.first)?.1.comment, "Road")
        XCTAssertEqual(store.revision, 1)
    }

    func testAddSkipsExistingAndDuplicateIdsAndRemoveSortsIndexes() async throws {
        let fixture = try CollectionStoreFixture()
        fixture.api.playlistHandler = { id in
            PlaylistDetail(
                playlist: Playlist(id: id, name: "Mix"),
                songs: [makeMediaSong("a")]
            )
        }
        fixture.api.playlistsHandler = { [Playlist(id: "playlist", name: "Mix")] }
        let updates = LockedTestBox<[PlaylistChanges]>([])
        fixture.api.updatePlaylistHandler = { _, changes in
            updates.update { $0.append(changes) }
        }
        let store = PlaylistsStore(repository: fixture.repository, api: fixture.api)

        let skipped = try await store.add(
            songIds: ["a", "b", "b", "c"],
            to: "playlist"
        )
        try await store.remove(indexes: [3, 1, 3], from: "playlist")

        XCTAssertEqual(skipped, ["a", "b"])
        XCTAssertEqual(updates.read { $0[0].songIdsToAdd }, ["b", "c"])
        XCTAssertEqual(updates.read { $0[1].songIndexesToRemove }, [1, 3])
        XCTAssertEqual(store.revision, 2)
    }

    func testNoOpAddMakesNoRequestAndDeleteUpdatesListAfterServerSuccess() async throws {
        let fixture = try CollectionStoreFixture()
        fixture.api.playlistHandler = { id in
            PlaylistDetail(
                playlist: Playlist(id: id, name: "Mix"),
                songs: [makeMediaSong("a")]
            )
        }
        fixture.api.playlistsHandler = { [Playlist(id: "playlist", name: "Mix")] }
        let updates = LockedTestBox(0)
        fixture.api.updatePlaylistHandler = { _, _ in updates.update { $0 += 1 } }
        let deleted = LockedTestBox<[String]>([])
        fixture.api.deletePlaylistHandler = { id in deleted.update { $0.append(id) } }
        let store = PlaylistsStore(repository: fixture.repository, api: fixture.api)
        await store.reload()

        let skipped = try await store.add(songIds: ["a", "a"], to: "playlist")
        try await store.delete("playlist")

        XCTAssertEqual(skipped, ["a", "a"])
        XCTAssertEqual(updates.read { $0 }, 0)
        XCTAssertEqual(deleted.read { $0 }, ["playlist"])
        XCTAssertTrue(store.playlists.isEmpty)
    }

    func testUpdateRefreshesAndReloadsAfterServerSuccess() async throws {
        let fixture = try CollectionStoreFixture()
        fixture.api.playlistsHandler = {
            [Playlist(id: "playlist", name: "Renamed", comment: "Note", isPublic: true)]
        }
        let updates = LockedTestBox<[PlaylistChanges]>([])
        fixture.api.updatePlaylistHandler = { _, changes in
            updates.update { $0.append(changes) }
        }
        let store = PlaylistsStore(repository: fixture.repository, api: fixture.api)

        try await store.update(
            "playlist",
            name: "Renamed",
            comment: "Note",
            isPublic: true
        )

        XCTAssertEqual(updates.read(\.first)?.name, "Renamed")
        XCTAssertEqual(updates.read(\.first)?.comment, "Note")
        XCTAssertEqual(updates.read(\.first)?.isPublic, true)
        XCTAssertEqual(store.playlists.first?.name, "Renamed")
        XCTAssertEqual(store.revision, 1)
    }
}

@MainActor
final class RadioStoreTests: XCTestCase {
    func testMutationsReloadInServerOrder() async throws {
        let api = FakeSubsonicAPI()
        let state = LockedTestBox([
            RadioStation(id: "one", name: "One", streamUrl: "https://one"),
            RadioStation(id: "two", name: "Two", streamUrl: "https://two"),
        ])
        api.radioStationsHandler = { state.read { $0 } }
        api.createRadioStationHandler = { name, streamURL, homePageURL in
            state.update {
                $0.append(RadioStation(
                    id: "three",
                    name: name,
                    streamUrl: streamURL,
                    homePageUrl: homePageURL
                ))
            }
        }
        api.updateRadioStationHandler = { station in
            state.update { values in
                values[values.firstIndex { $0.id == station.id }!] = station
            }
        }
        api.deleteRadioStationHandler = { id in
            state.update { $0.removeAll { $0.id == id } }
        }
        let store = RadioStore(api: api)

        await store.load()
        try await store.create(
            name: "Three",
            streamUrl: "https://three",
            homePageUrl: nil
        )
        try await store.update(RadioStation(
            id: "two",
            name: "Second",
            streamUrl: "https://two"
        ))
        try await store.delete("one")

        XCTAssertEqual(store.stations.map(\.id), ["two", "three"])
        XCTAssertEqual(store.stations.first?.name, "Second")
        XCTAssertEqual(store.phase, .loaded)
    }
}

@MainActor
final class ListeningHistoryStoreTests: XCTestCase {
    func testSongJSONRoundTripCoversEveryParsedField() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let original = makeCompleteHistorySong()
        try preferences.addToPlayHistory(songJSON: original.playHistoryJSON())
        let store = ListeningHistoryStore(preferences: preferences)

        store.load()

        XCTAssertEqual(store.songs, [original])
    }

    func testRecordKeepsOlderDuplicateAndRemoveRewritesStorage() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let store = ListeningHistoryStore(preferences: preferences)
        store.maxSize = 10
        let a = makeMediaSong("a")
        let b = makeMediaSong("b")

        store.record(a)
        store.record(b)
        store.record(a)
        XCTAssertEqual(store.songs.map(\.id), ["a", "b", "a"])
        store.remove(at: 1)

        let restored = ListeningHistoryStore(preferences: preferences)
        restored.load()
        XCTAssertEqual(restored.songs.map(\.id), ["a", "a"])
        store.clear()
        XCTAssertTrue(try preferences.getPlayHistory().isEmpty)
    }

    func testPlaybackTracksOnlyAccumulatedLocalPlayingTime() throws {
        let database = try TemporaryDatabase()
        let store = ListeningHistoryStore(
            preferences: PreferencesService(db: database.manager.dbPool)
        )
        let song = makeMediaSong("tracked")
        let start = Date(timeIntervalSince1970: 1_000)

        store.trackPlayback(song: song, isPlaying: true, isRemote: false, now: start)
        store.trackPlayback(
            song: song,
            isPlaying: false,
            isRemote: false,
            now: start.addingTimeInterval(6)
        )
        store.trackPlayback(
            song: song,
            isPlaying: true,
            isRemote: false,
            now: start.addingTimeInterval(20)
        )
        store.trackPlayback(
            song: song,
            isPlaying: true,
            isRemote: true,
            now: start.addingTimeInterval(25)
        )
        store.trackPlayback(
            song: song,
            isPlaying: true,
            isRemote: false,
            now: start.addingTimeInterval(40)
        )
        store.trackPlayback(
            song: nil,
            isPlaying: true,
            isRemote: false,
            now: start.addingTimeInterval(41)
        )

        XCTAssertEqual(store.songs.map(\.id), ["tracked"])

        let remoteOnly = makeMediaSong("remote")
        store.trackPlayback(
            song: remoteOnly,
            isPlaying: true,
            isRemote: true,
            now: start.addingTimeInterval(50)
        )
        store.trackPlayback(
            song: nil,
            isPlaying: true,
            isRemote: false,
            now: start.addingTimeInterval(100)
        )
        XCTAssertEqual(store.songs.map(\.id), ["tracked"])
    }
}

private final class StubLibrarySyncHTTPClient: LibrarySyncHTTPClient {
    typealias Handler = (
        String,
        String,
        ServerCredentials,
        [String: String],
        String
    ) async throws -> SubsonicResponse

    let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String],
        method: String
    ) async throws -> SubsonicResponse {
        try await handler(baseUrl, path, credentials, extraQuery, method)
    }
}

private struct CollectionStoreFixture {
    let database: TemporaryDatabase
    let api: FakeSubsonicAPI
    let library: LibraryService
    let repository: LibraryRepository

    init() throws {
        database = try TemporaryDatabase()
        api = FakeSubsonicAPI()
        let httpClient = StubLibrarySyncHTTPClient { _, _, _, query, _ in
            let id = query["id"] ?? "playlist"
            return SubsonicResponse(data: [
                "playlist": [
                    "id": id,
                    "name": "Mix",
                    "songCount": 0,
                    "duration": 0,
                    "public": false,
                    "entry": [],
                ],
            ], count: 0)
        }
        library = makeCollectionLibrary(database: database, httpClient: httpClient)
        repository = LibraryRepository(
            api: api,
            library: library,
            connectivity: FixedConnectivity()
        )
    }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private func makeCollectionLibrary(
    database: TemporaryDatabase,
    httpClient: any LibrarySyncHTTPClient
) -> LibraryService {
    let credentials = ServerCredentials(
        serverUrl: "https://music.example",
        username: "alice",
        password: "secret",
        authType: "password",
        protocolVersion: "1.16.1",
        serverType: "navidrome",
        fallbackUrl: nil
    )
    return LibraryService(
        dbManager: database.manager,
        httpClient: httpClient,
        credentialsProvider: { credentials }
    )
}

private func makeCollectionArtistRecord(_ id: String) -> ArtistRecord {
    ArtistRecord(
        id: id,
        name: "Artist \(id)",
        albumCount: 1,
        coverArt: nil,
        artistImageUrl: nil,
        starred: nil,
        starredAt: nil,
        musicBrainzId: nil,
        sortName: nil
    )
}

private func makeCollectionAlbumRecord(
    _ id: String,
    name: String? = nil,
    played: String? = nil
) -> AlbumRecord {
    AlbumRecord(
        id: id,
        name: name ?? "Album \(id)",
        artist: "Artist",
        artistId: "artist",
        coverArt: nil,
        songCount: 1,
        duration: 180,
        year: 2026,
        genre: nil,
        created: "2026-01-01T00:00:00.000Z",
        played: played,
        playCount: nil,
        starred: nil,
        starredAt: nil
    )
}

private func makeCollectionSongRecord(
    _ id: String,
    albumId: String = "album"
) -> SongRecord {
    var record = makeSongRecord(id)
    record.albumId = albumId
    return record
}

private func makeMediaSong(_ id: String) -> Song {
    Song(
        id: id,
        title: "Song \(id)",
        album: "Album",
        albumId: "album",
        artist: "Artist",
        artistId: "artist",
        duration: 180
    )
}

private func makeCompleteHistorySong() -> Song {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000.123)
    return Song(
        id: "complete",
        parent: "parent",
        title: "Complete",
        album: "Album",
        albumId: "album",
        artist: "Artist",
        artistId: "artist",
        artists: [ArtistCredit(id: "artist", name: "Artist")],
        displayArtist: "Artist feat. Guest",
        albumArtists: [ArtistCredit(id: "album-artist", name: "Album Artist")],
        displayAlbumArtist: "Album Artist",
        displayComposer: "Composer",
        contributors: [Contributor(
            role: "composer",
            subRole: "music",
            artist: ArtistCredit(id: "composer", name: "Composer")
        )],
        track: 2,
        discNumber: 1,
        year: 2026,
        genre: "Rock",
        genres: ["Rock", "Alternative"],
        coverArt: "cover",
        duration: 245,
        bitRate: 1_000,
        bitDepth: 24,
        samplingRate: 96_000,
        channelCount: 2,
        size: 12_345_678,
        suffix: "flac",
        contentType: "audio/flac",
        path: "Artist/Album/Song.flac",
        playCount: 12,
        played: timestamp,
        created: timestamp,
        starred: timestamp,
        userRating: 5,
        bpm: 123,
        comment: "Comment",
        musicBrainzId: "musicbrainz",
        replayGain: ReplayGainInfo(
            trackGain: -5,
            trackPeak: 0.9,
            albumGain: -4,
            albumPeak: 0.8,
            baseGain: 0,
            fallbackGain: -6
        ),
        explicitStatus: .clean,
        mediaType: "song",
        sortName: "Complete, The"
    )
}
