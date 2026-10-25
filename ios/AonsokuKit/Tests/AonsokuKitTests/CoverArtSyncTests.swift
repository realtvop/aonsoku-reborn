import Foundation
import XCTest
@testable import AonsokuKit

@MainActor
final class CoverArtSyncTests: XCTestCase {
    func testDeduplicatesIdentifiersSkipsLargeEnoughFilesAndReportsProgress() async throws {
        let database = try TemporaryDatabase()
        try seedCoverRecords(database)
        let tracker = CoverDownloadTracker(delay: .milliseconds(5))
        let engine = SyncEngine(
            db: database.manager.dbPool,
            httpClient: CoverSyncHTTPClient(),
            credentialsProvider: { nil },
            cachedCoverSize: { $0 == "shared" ? "900" : nil },
            downloadCover: { id, _ in try await tracker.download(id) }
        )
        let states = SyncStateRecorder()
        engine.onSyncStateChanged = { states.append($0) }

        try await engine.runCoverArt(
            options: .init(
                concurrency: 2,
                useAlbumCoverForSongs: true,
                size: "700"
            ),
            serverType: "navidrome"
        )
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            Set(tracker.downloaded),
            Set(["artist-1", "album-1", "playlist-cover"])
        )
        XCTAssertFalse(tracker.downloaded.contains("song-cover"))
        XCTAssertLessThanOrEqual(tracker.maximumActive, 2)
        XCTAssertEqual(states.latest?["phase"] as? String, "coverArt")
        XCTAssertEqual(states.latest?["processedItems"] as? Int, 4)
        XCTAssertEqual(states.latest?["totalItems"] as? Int, 4)
    }

    func testSongCoversAreIncludedAndLMSDoesNotUseArtistIds() async throws {
        let database = try TemporaryDatabase()
        try seedCoverRecords(database)
        let tracker = CoverDownloadTracker(delay: .zero)
        let engine = SyncEngine(
            db: database.manager.dbPool,
            httpClient: CoverSyncHTTPClient(),
            credentialsProvider: { nil },
            downloadCover: { id, _ in try await tracker.download(id) }
        )

        try await engine.runCoverArt(
            options: .init(
                concurrency: 8,
                useAlbumCoverForSongs: false,
                size: "700"
            ),
            serverType: "lms"
        )
        XCTAssertEqual(
            Set(tracker.downloaded),
            Set(["shared", "playlist-cover", "song-cover"])
        )
        XCTAssertFalse(tracker.downloaded.contains("artist-1"))
        XCTAssertFalse(tracker.downloaded.contains("album-1"))
    }

    func testConcurrencyLimitAndCancellation() async throws {
        let database = try TemporaryDatabase()
        try ArtistRepository(db: database.manager.dbPool).bulkUpsert(
            (0..<8).map {
                ArtistRecord(
                    id: "artist-\($0)",
                    name: "Artist \($0)",
                    albumCount: 0,
                    coverArt: "cover-\($0)",
                    artistImageUrl: nil,
                    starred: nil,
                    starredAt: nil,
                    musicBrainzId: nil,
                    sortName: nil
                )
            }
        )
        let tracker = CoverDownloadTracker(delay: .seconds(5))
        let engine = SyncEngine(
            db: database.manager.dbPool,
            httpClient: CoverSyncHTTPClient(),
            credentialsProvider: { nil },
            downloadCover: { id, _ in try await tracker.download(id) }
        )
        let task = Task {
            try await engine.runCoverArt(
                options: .init(
                    concurrency: 3,
                    useAlbumCoverForSongs: false,
                    size: "700"
                ),
                serverType: "lms"
            )
        }
        let deadline = Date().addingTimeInterval(1)
        while tracker.startedCount < 3, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(tracker.startedCount, 3)
        XCTAssertEqual(tracker.maximumActive, 3)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertLessThan(tracker.downloaded.count, 8)
    }

    private func seedCoverRecords(_ database: TemporaryDatabase) throws {
        try ArtistRepository(db: database.manager.dbPool).upsert(ArtistRecord(
            id: "artist-1",
            name: "Artist",
            albumCount: 1,
            coverArt: "shared",
            artistImageUrl: nil,
            starred: nil,
            starredAt: nil,
            musicBrainzId: nil,
            sortName: nil
        ))
        try AlbumRepository(db: database.manager.dbPool).upsert(AlbumRecord(
            id: "album-1",
            name: "Album",
            artist: "Artist",
            artistId: "artist-1",
            coverArt: "shared",
            songCount: 1,
            duration: 180,
            year: nil,
            genre: nil,
            created: nil,
            played: nil,
            playCount: nil,
            starred: nil,
            starredAt: nil
        ))
        try PlaylistRepository(db: database.manager.dbPool).upsert(PlaylistRecord(
            id: "playlist-1",
            name: "Playlist",
            comment: nil,
            songCount: 1,
            duration: 180,
            isPublic: false,
            owner: nil,
            created: nil,
            changed: nil,
            coverArt: "playlist-cover",
            starred: nil,
            starredAt: nil
        ))
        var song = makeSongRecord("song-1")
        song.coverArt = "song-cover"
        try SongRepository(db: database.manager.dbPool).upsert(song)
    }
}

private struct CoverSyncHTTPClient: LibrarySyncHTTPClient {
    func request(
        baseUrl: String,
        path: String,
        credentials: ServerCredentials,
        extraQuery: [String: String],
        method: String
    ) async throws -> SubsonicResponse {
        throw SubsonicAPIError.unsupported
    }
}

private final class CoverDownloadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private var active = 0
    private var maximum = 0
    private var started: [String] = []
    private var finished: [String] = []

    init(delay: Duration) {
        self.delay = delay
    }

    var startedCount: Int { withLock { started.count } }
    var activeCount: Int { withLock { active } }
    var maximumActive: Int { withLock { maximum } }
    var downloaded: [String] { withLock { finished } }

    func download(_ id: String) async throws {
        begin(id)
        do {
            if delay != .zero { try await Task.sleep(for: delay) }
            complete(id)
        } catch {
            fail()
            throw error
        }
    }

    private func begin(_ id: String) {
        withLock {
            started.append(id)
            active += 1
            maximum = max(maximum, active)
        }
    }

    private func complete(_ id: String) {
        withLock {
            active -= 1
            finished.append(id)
        }
    }

    private func fail() {
        withLock { active -= 1 }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SyncStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: Any]] = []

    var latest: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    func append(_ state: [String: Any]) {
        lock.lock()
        values.append(state)
        lock.unlock()
    }
}
