import UIKit
import XCTest
@testable import AonsokuKit

final class LibraryRepositoryTests: XCTestCase {
    func testLocalAlbumFiltersAndPaging() async throws {
        let fixture = try LibraryFixture()
        let repository = fixture.repository()

        let byName = try await repository.albums(.alphabeticalByName, offset: 0, limit: 2)
        XCTAssertEqual(byName.items.map(\.id), ["a2", "a1"])
        XCTAssertEqual(byName.total, 3)
        XCTAssertTrue(byName.hasMore)
        let byArtist = try await repository.albums(
            .alphabeticalByArtist,
            offset: 0,
            limit: 10
        )
        let recentlyAdded = try await repository.albums(.recentlyAdded, offset: 0, limit: 10)
        let recentlyPlayed = try await repository.albums(.recentlyPlayed, offset: 0, limit: 10)
        let mostPlayed = try await repository.albums(.mostPlayed, offset: 0, limit: 10)
        let random = try await repository.albums(.random, offset: 0, limit: 10)
        let favorites = try await repository.albums(.favorites, offset: 0, limit: 10)
        let newest = try await repository.albums(
            .byYear(newestFirst: true),
            offset: 0,
            limit: 10
        )
        let oldest = try await repository.albums(
            .byYear(newestFirst: false),
            offset: 0,
            limit: 10
        )
        let genre = try await repository.albums(.byGenre("Rock"), offset: 0, limit: 10)
        let discography = try await repository.albums(
            .discography(artistId: "artist-1"),
            offset: 0,
            limit: 10
        )
        let search = try await repository.albums(.search("cafe b"), offset: 0, limit: 10)
        let emptySearch = try await repository.albums(.search("   "), offset: 0, limit: 10)
        XCTAssertEqual(byArtist.items.map(\.id), ["a2", "a3", "a1"])
        XCTAssertEqual(recentlyAdded.items.map(\.id), ["a2", "a3", "a1"])
        XCTAssertEqual(recentlyPlayed.items.map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(mostPlayed.items.map(\.id), ["a3", "a1", "a2"])
        XCTAssertEqual(Set(random.items.map(\.id)), Set(["a1", "a2", "a3"]))
        XCTAssertEqual(favorites.items.map(\.id), ["a3", "a1"])
        XCTAssertEqual(newest.items.map(\.id), ["a2", "a3", "a1"])
        XCTAssertEqual(oldest.items.map(\.id), ["a1", "a3", "a2"])
        XCTAssertEqual(genre.items.map(\.id), ["a2", "a1"])
        XCTAssertEqual(discography.items.map(\.id), ["a3", "a1"])
        XCTAssertEqual(search.items.map(\.id), ["a3"])
        XCTAssertTrue(emptySearch.items.isEmpty)
    }

    func testLocalSongScopesSortsMappingAndSearch() async throws {
        let fixture = try LibraryFixture()
        let repository = fixture.repository()

        let artist = try await repository.songs(
            SongListQuery(
                scope: .artist(id: "artist-1", name: "Artist One"),
                sort: .title,
                ascending: true
            ),
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(artist.items.map(\.id), ["s1", "s3", "s2"])

        let album = try await repository.songs(
            SongListQuery(scope: .album(id: "a1")),
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(album.items.map(\.id), ["s2", "s1"])

        let favorites = try await repository.songs(
            SongListQuery(scope: .favorites),
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(favorites.items.map(\.id), ["s3"])
        XCTAssertEqual(favorites.items.first?.genres, ["Jazz", "Fusion"])
        XCTAssertEqual(favorites.items.first?.replayGain?.trackGain, -4.5)
        XCTAssertEqual(favorites.items.first?.size, 4_000_000)
        let created = try XCTUnwrap(favorites.items.first?.created)
        XCTAssertEqual(created.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        let genre = try await repository.songs(
            SongListQuery(scope: .genre("Rock"), sort: .album, ascending: true),
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(genre.items.map(\.id), ["s1", "s2"])

        let search = try await repository.songs(
            SongListQuery(search: "resume guest", sort: .title, ascending: true),
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(search.items.map(\.id), ["s2"])

        let recentlyAdded = try await repository.songs(
            SongListQuery(sort: .recentlyAdded, ascending: false),
            offset: 0,
            limit: 10
        )
        let titles = try await repository.songs(
            SongListQuery(sort: .title, ascending: true),
            offset: 0,
            limit: 10
        )
        let artists = try await repository.songs(
            SongListQuery(sort: .artist, ascending: true),
            offset: 0,
            limit: 10
        )
        let albums = try await repository.songs(
            SongListQuery(sort: .album, ascending: true),
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(recentlyAdded.items.map(\.id), ["s2", "s1", "s3"])
        XCTAssertEqual(titles.items.map(\.id), ["s1", "s3", "s2"])
        XCTAssertEqual(artists.items.map(\.artist), ["Artist One", "Artist One", "Guest Artist"])
        XCTAssertEqual(albums.items.map(\.album), ["Beta", "Beta", "Café Nights"])
    }

    func testServerSelectionDialectAndPageValues() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        let calls = LockedTestBox<(query: String?, albumType: AlbumListType?)>((nil, nil))
        api.searchHandler = { query, _ in
            calls.update { $0.query = query }
            return SearchResults(songs: [Song(id: "server", title: "Server")])
        }
        api.albumListHandler = { type, _, _, _, _, _ in
            calls.update { $0.albumType = type }
            return [Album(id: "album", name: "Album")]
        }
        let repository = LibraryRepository(
            api: api,
            library: LibraryService(dbManager: database.manager),
            connectivity: FixedConnectivity(),
            serverType: { "navidrome" }
        )

        let songs = try await repository.songs(SongListQuery(), offset: 20, limit: 1)
        XCTAssertEqual(calls.read(\.query), "\"\"")
        XCTAssertEqual(songs.total, 21)
        XCTAssertTrue(songs.hasMore)

        _ = try await repository.albums(.recentlyPlayed, offset: 0, limit: 5)
        XCTAssertEqual(calls.read(\.albumType), .recent)
    }

    func testDetailsFallBackOnlyForConnectivityFailures() async throws {
        let fixture = try LibraryFixture()
        let api = FakeSubsonicAPI()
        api.albumHandler = { _ in throw SubsonicAPIError.timedOut }
        let repository = fixture.repository(api: api)

        let cached = try await repository.album(id: "a1")
        XCTAssertEqual(cached.album.id, "a1")
        XCTAssertEqual(cached.songs.map(\.id), ["s2", "s1"])

        api.albumHandler = { _ in
            throw SubsonicAPIError.notAuthorized(message: "denied")
        }
        do {
            _ = try await repository.album(id: "a1")
            XCTFail("Expected the server error")
        } catch {
            XCTAssertEqual(
                error as? SubsonicAPIError,
                .notAuthorized(message: "denied")
            )
        }

        let offline = fixture.repository(connectivity: FixedConnectivity(isOnline: false))
        let offlineAlbum = try await offline.album(id: "a2")
        XCTAssertEqual(offlineAlbum.album.id, "a2")
    }

    func testSongsByIdsKeepOrderAndSkipUnknownIds() async throws {
        let fixture = try LibraryFixture()
        let api = FakeSubsonicAPI()
        api.songHandler = { id in
            if id == "remote" { return Song(id: id, title: "Remote") }
            throw SubsonicAPIError.notFound(message: id)
        }
        let repository = fixture.repository(api: api)

        let result = try await repository.songs(ids: ["remote", "s1", "missing", "remote"])
        XCTAssertEqual(result.map(\.id), ["remote", "s1", "remote"])
    }

    func testOfflineSearchRequiresEveryNormalizedWord() async throws {
        let fixture = try LibraryFixture()
        let repository = fixture.repository(connectivity: FixedConnectivity(isOnline: false))

        let result = try await repository.search("cafe b")
        XCTAssertEqual(result.albums.map(\.id), ["a3"])
        XCTAssertTrue(result.artists.isEmpty)
        XCTAssertTrue(result.songs.isEmpty)
        let empty = try await repository.search("   ")
        XCTAssertTrue(empty.isEmpty)
    }
}

@MainActor
final class HomeStoreTests: XCTestCase {
    func testConcurrentInitialLoadRunsOnceAndFailedSectionKeepsOldAlbums() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        let state = LockedTestBox((calls: 0, failFrequent: false))
        api.albumListHandler = { type, size, _, _, _, _ in
            state.update { $0.calls += 1 }
            if type == .frequent, state.read(\.failFrequent) {
                throw SubsonicAPIError.notAuthorized(message: "denied")
            }
            return [Album(id: "\(type.rawValue)-\(size)", name: type.rawValue)]
        }
        let repository = LibraryRepository(
            api: api,
            library: LibraryService(dbManager: database.manager),
            connectivity: FixedConnectivity()
        )
        let store = HomeStore(repository: repository)

        async let first: Void = store.loadIfNeeded()
        async let second: Void = store.loadIfNeeded()
        _ = await (first, second)
        XCTAssertEqual(state.read(\.calls), 5)
        XCTAssertEqual(store.phase, .loaded)
        let oldFrequent = store.albums(in: .mostPlayed)

        state.update { $0.failFrequent = true }
        await store.refresh()
        XCTAssertEqual(store.albums(in: .mostPlayed), oldFrequent)
        XCTAssertEqual(store.phase, .loaded)

        let calls = state.read(\.calls)
        await store.loadIfNeeded()
        XCTAssertEqual(state.read(\.calls), calls)
    }

    func testRandomSnapshotsSurviveStartupAndDynamicRefreshUntilExpiry() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let api = FakeSubsonicAPI()
        let calls = LockedTestBox(0)
        let clock = LockedTestBox(Date(timeIntervalSince1970: 1_800_000_000))
        api.albumListHandler = { type, size, _, _, _, _ in
            calls.update { $0 += 1 }
            let number = calls.read { $0 }
            return [Album(id: "\(type.rawValue)-\(size)-\(number)", name: type.rawValue)]
        }
        let repository = LibraryRepository(
            api: api, library: LibraryService(dbManager: database.manager), connectivity: FixedConnectivity()
        )
        func restoredStore() -> HomeStore {
            let store = HomeStore(repository: repository, preferences: preferences, now: { clock.read { $0 } })
            store.restoreCached(accountKey: "server:user")
            return store
        }
        let initial = restoredStore()
        await initial.loadIfNeeded()
        let carousel = initial.carousel
        let explore = initial.albums(in: .explore)
        XCTAssertEqual(calls.read { $0 }, 5)

        clock.update { $0 += 12 * 60 * 60 }
        let restarted = restoredStore()
        await restarted.loadIfNeeded()
        XCTAssertEqual(calls.read { $0 }, 8)
        XCTAssertEqual(restarted.carousel, carousel)
        XCTAssertEqual(restarted.albums(in: .explore), explore)
        await restarted.refreshAutomatically()
        XCTAssertEqual(calls.read { $0 }, 11)
        XCTAssertEqual(restarted.carousel, carousel)

        // Dynamic refreshes must not extend the random lists' original lifetime.
        clock.update { $0 += 13 * 60 * 60 }
        let expired = restoredStore()
        await expired.loadIfNeeded()
        XCTAssertEqual(calls.read { $0 }, 16)
        XCTAssertNotEqual(expired.carousel, carousel)
        let beforeManual = expired.carousel
        await expired.refresh()
        XCTAssertEqual(calls.read { $0 }, 21)
        XCTAssertNotEqual(expired.carousel, beforeManual)
    }

    func testInitialTotalFailureSetsFailedPhase() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        api.albumListHandler = { _, _, _, _, _, _ in
            throw SubsonicAPIError.notAuthorized(message: "denied")
        }
        let store = HomeStore(repository: LibraryRepository(
            api: api,
            library: LibraryService(dbManager: database.manager),
            connectivity: FixedConnectivity()
        ))

        await store.refresh()
        XCTAssertEqual(store.phase, .failed("denied"))
    }
}

@MainActor
final class ArtworkProviderTests: XCTestCase {
    func testMemorySizeReuseConcurrentDedupPaletteAndPurge() async throws {
        let database = try TemporaryDatabase()
        let library = LibraryService(dbManager: database.manager)
        let id = "artwork-test-\(UUID().uuidString)"
        let image = makeQuadrantImage()
        let data = try XCTUnwrap(image.pngData())
        _ = try library.storeCover(
            id: id,
            data: data,
            contentType: "image/png",
            size: ArtworkSize.large.requestValue
        )
        defer { _ = try? library.deleteCover(id: id) }
        let provider = ArtworkProvider(library: library)

        async let first = provider.image(for: id, size: .medium)
        async let second = provider.image(for: id, size: .medium)
        let loaded = await (first, second)
        XCTAssertNotNil(loaded.0)
        XCTAssertTrue(loaded.0 === loaded.1)
        XCTAssertTrue(provider.cachedImage(for: id, size: .small) === loaded.0)
        // A smaller image only stands in for a larger one; it never satisfies it.
        XCTAssertNil(provider.cachedImage(for: id, size: .large))
        XCTAssertTrue(provider.previewImage(for: id, size: .large) === loaded.0)
        XCTAssertNil(provider.previewImage(for: id, size: .medium))

        let extracted = await provider.palette(for: id)
        let palette = try XCTUnwrap(extracted)
        XCTAssertEqual(palette.colors.count, 4)
        // Equal red/green/blue/yellow quadrants: RMS differs from both
        // the dominant bucket and arithmetic average used by other algorithms.
        let average = try XCTUnwrap(palette.average)
        XCTAssertEqual(average.red, sqrt(0.5), accuracy: 0.03)
        XCTAssertEqual(average.green, sqrt(0.5), accuracy: 0.03)
        XCTAssertEqual(average.blue, 0.5, accuracy: 0.03)
        XCTAssertFalse(palette.colors.contains { color in
            color.red.isNaN || color.green.isNaN || color.blue.isNaN
        })

        provider.purgeMemory()
        XCTAssertNil(provider.cachedImage(for: id, size: .small))
        XCTAssertNil(provider.previewImage(for: id, size: .large))
    }

    func testPurgeRejectsInFlightPaletteExtraction() async throws {
        let database = try TemporaryDatabase()
        let library = LibraryService(dbManager: database.manager)
        let id = "palette-purge-\(UUID().uuidString)"
        let image = makeQuadrantImage()
        _ = try library.storeCover(
            id: id,
            data: try XCTUnwrap(image.pngData()),
            contentType: "image/png",
            size: ArtworkSize.large.requestValue
        )
        defer { _ = try? library.deleteCover(id: id) }

        let gate = PaletteExtractionGate()
        let calls = LockedTestBox(0)
        let stalePalette = ArtworkPalette(
            colors: [RGBColor(red: 1, green: 0, blue: 0)],
            isDark: false
        )
        let freshPalette = ArtworkPalette(
            colors: [RGBColor(red: 0, green: 0, blue: 1)],
            isDark: true
        )
        let provider = ArtworkProvider(library: library) { _ in
            let call = calls.read { $0 }
            calls.update { $0 += 1 }
            if call == 0 {
                await gate.block()
                return stalePalette
            }
            return freshPalette
        }

        let extraction = Task { await provider.palette(for: id) }
        await gate.waitUntilBlocked()
        provider.purgeMemory()
        await gate.release()

        let discarded = await extraction.value
        let loaded = await provider.palette(for: id)
        let cached = await provider.palette(for: id)
        XCTAssertNil(discarded)
        XCTAssertEqual(loaded, freshPalette)
        XCTAssertEqual(cached, freshPalette)
        XCTAssertEqual(calls.read { $0 }, 2)
    }

    func testPurgeCannotRaceWithInFlightImagePublication() async throws {
        let database = try TemporaryDatabase()
        let library = LibraryService(dbManager: database.manager)
        let id = "image-purge-\(UUID().uuidString)"
        let gate = PaletteExtractionGate()
        let calls = LockedTestBox(0)
        let staleImage = makeQuadrantImage()
        let freshImage = makeQuadrantImage()
        let provider = ArtworkProvider(
            library: library,
            coverLoader: { _, _ in
                let call = calls.read { $0 }
                calls.update { $0 += 1 }
                if call == 0 {
                    await gate.block()
                    return staleImage
                }
                return freshImage
            },
            paletteExtractor: { _ in nil }
        )

        let request = Task { await provider.image(for: id, size: .medium) }
        await gate.waitUntilBlocked()
        provider.purgeMemory()
        await gate.release()

        let discarded = await request.value
        let loaded = await provider.image(for: id, size: .medium)
        XCTAssertNil(discarded)
        XCTAssertTrue(loaded === freshImage)
        XCTAssertTrue(provider.cachedImage(for: id, size: .medium) === freshImage)
        XCTAssertEqual(calls.read { $0 }, 2)
    }

    private func makeQuadrantImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.green.setFill()
            context.fill(CGRect(x: 64, y: 0, width: 64, height: 64))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 64, width: 64, height: 64))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 64, y: 64, width: 64, height: 64))
        }
    }
}

private actor PaletteExtractionGate {
    private var isBlocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

final class NetworkMonitorTests: XCTestCase {
    func testLockedConnectivityPublishesAtomicSnapshots() {
        let connectivity = LockedConnectivity(isOnline: true, isMetered: false)
        XCTAssertTrue(connectivity.isOnline)
        XCTAssertFalse(connectivity.isMetered)
        connectivity.update(isOnline: false, isMetered: true)
        XCTAssertFalse(connectivity.isOnline)
        XCTAssertTrue(connectivity.isMetered)
    }
}

private final class LibraryFixture {
    let database: TemporaryDatabase
    let library: LibraryService

    init() throws {
        database = try TemporaryDatabase()
        library = LibraryService(dbManager: database.manager)
        try ArtistRepository(db: database.manager.dbPool).bulkUpsert([
            makeArtist("artist-1", name: "Artist One"),
            makeArtist("artist-2", name: "Artist Two"),
        ])
        try AlbumRepository(db: database.manager.dbPool).bulkUpsert([
            makeAlbum(
                "a1",
                name: "Beta",
                artist: "Zed",
                artistId: "artist-1",
                year: 2020,
                genre: "Rock",
                created: "2026-01-01T00:00:00Z",
                played: "2026-01-04T00:00:00Z",
                playCount: 5,
                starred: "2026-01-01T00:00:00Z",
                starredAt: 10
            ),
            makeAlbum(
                "a2",
                name: "Alpha",
                artist: "Able",
                artistId: "artist-2",
                year: 2024,
                genre: "Rock",
                created: "2026-01-03T00:00:00Z",
                played: "2026-01-02T00:00:00Z",
                playCount: 1
            ),
            makeAlbum(
                "a3",
                name: "Café Nights",
                artist: "Bravo",
                artistId: "artist-1",
                year: 2022,
                genre: "Jazz",
                created: "2026-01-02T00:00:00Z",
                playCount: 10,
                starred: "2026-01-03T00:00:00Z",
                starredAt: 30
            ),
        ])
        try SongRepository(db: database.manager.dbPool).bulkUpsert([
            makeLibrarySong(
                "s1",
                title: "Alpha Song",
                album: "Beta",
                albumId: "a1",
                artist: "Artist One",
                artistId: "artist-1",
                track: 2,
                genre: "Rock",
                created: "2026-01-01T00:00:00Z"
            ),
            makeLibrarySong(
                "s2",
                title: "Résumé",
                album: "Beta",
                albumId: "a1",
                artist: "Guest Artist",
                artistId: "guest",
                track: 1,
                genre: "Rock",
                created: "2026-01-02T00:00:00Z"
            ),
            makeLibrarySong(
                "s3",
                title: "Gamma",
                album: "Café Nights",
                albumId: "a3",
                artist: "Artist One",
                artistId: "artist-1",
                track: 1,
                genre: "Jazz",
                created: "1700000000000",
                starred: "2026-01-03T00:00:00Z",
                genresJSON: "[{\"name\":\"Jazz\"},{\"name\":\"Fusion\"}]",
                replayGainJSON: "{\"trackGain\":-4.5,\"trackPeak\":0.8}",
                size: 4_000_000
            ),
        ])
        try SyncStateRepository(db: database.manager.dbPool).recordFullSync()
    }

    func repository(
        api: FakeSubsonicAPI = FakeSubsonicAPI(),
        connectivity: any Connectivity = FixedConnectivity()
    ) -> LibraryRepository {
        LibraryRepository(api: api, library: library, connectivity: connectivity)
    }
}

private func makeArtist(_ id: String, name: String) -> ArtistRecord {
    ArtistRecord(
        id: id,
        name: name,
        albumCount: 2,
        coverArt: nil,
        artistImageUrl: nil,
        starred: nil,
        starredAt: nil,
        musicBrainzId: nil,
        sortName: nil
    )
}

private func makeAlbum(
    _ id: String,
    name: String,
    artist: String,
    artistId: String,
    year: Int,
    genre: String,
    created: String,
    played: String? = nil,
    playCount: Int,
    starred: String? = nil,
    starredAt: Int? = nil
) -> AlbumRecord {
    AlbumRecord(
        id: id,
        name: name,
        artist: artist,
        artistId: artistId,
        coverArt: nil,
        songCount: 2,
        duration: 360,
        year: year,
        genre: genre,
        created: created,
        played: played,
        playCount: playCount,
        starred: starred,
        starredAt: starredAt
    )
}

private func makeLibrarySong(
    _ id: String,
    title: String,
    album: String,
    albumId: String,
    artist: String,
    artistId: String,
    track: Int,
    genre: String,
    created: String,
    starred: String? = nil,
    genresJSON: String? = nil,
    replayGainJSON: String? = nil,
    size: Int? = nil
) -> SongRecord {
    SongRecord(
        id: id,
        parent: albumId,
        title: title,
        album: album,
        artist: artist,
        track: track,
        year: 2026,
        genre: genre,
        coverArt: nil,
        size: size,
        contentType: "audio/flac",
        suffix: "flac",
        duration: 180,
        bitRate: 1_000,
        path: nil,
        playCount: nil,
        discNumber: 1,
        created: created,
        albumId: albumId,
        artistId: artistId,
        played: nil,
        starred: starred,
        starredAt: starred == nil ? nil : 1,
        playedAt: nil,
        bpm: nil,
        comment: nil,
        sortName: nil,
        mediaType: "song",
        musicBrainzId: nil,
        genresJson: genresJSON,
        replayGainJson: replayGainJSON
    )
}
