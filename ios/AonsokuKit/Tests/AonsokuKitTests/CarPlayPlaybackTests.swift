import CarPlay
import XCTest
@testable import AonsokuKit

@MainActor
final class CarPlayPlaybackTests: XCTestCase {
    func testTemplatesUseNativeServicesAndSystemTabs() throws {
        let fixture = try PlayerStoreTestFixture()
        let library = CarPlayLibraryProvider(db: fixture.database.manager.dbPool,
            credentials: { nil }, cacheDirectories: [])
        let controller = CarPlayTemplateController(library: library, playback: fixture.audio)
        let root = controller.makeRootTemplate()
        XCTAssertEqual(root.templates.count, 3)
        XCTAssertTrue(root.templates.allSatisfy { $0 is CPListTemplate })
        XCTAssertNil(fixture.audio.fullState())
        fixture.audio.shutdown()
    }

    func testQueueIncludesDuplicateOccurrencesAndRejectsStaleSelections() async throws {
        let fixture = try PlayerStoreTestFixture()
        let songs = try ["one", "two", "one"].map { try localSong($0, fixture: fixture) }
        fixture.audio.setContextQueue(songs: songs, currentIndex: 0, autoplay: false)
        let first = await snapshot(fixture.audio)
        XCTAssertEqual(first.queue.map(\.id), ["one", "two", "one"])
        XCTAssertEqual(first.queue.map(\.index), [0, 1, 2])
        fixture.audio.reorderContextQueue(from: 1, to: 2)
        _ = fixture.audio.fullState() // Drain the serial command queue.
        let result = await withCheckedContinuation { continuation in
            fixture.audio.performCarPlay(.queueEntry(first.queue[1])) { continuation.resume(returning: $0) }
        }
        if case .success = result { XCTFail("An older row must never select a new occurrence") }
        let second = await snapshot(fixture.audio)
        XCTAssertEqual(second.queue.map(\.id), ["one", "one", "two"])
        fixture.audio.shutdown()
    }

    func testQueuePaginationUsesActualOffsets() async throws {
        let fixture = try PlayerStoreTestFixture()
        let songs = try (0..<150).map { try localSong("song-\($0)", fixture: fixture) }
        fixture.audio.setContextQueue(songs: songs, currentIndex: 0, autoplay: false)
        let first = await snapshot(fixture.audio, offset: 0, limit: 40)
        let second = await snapshot(fixture.audio, offset: 40, limit: 40)
        XCTAssertEqual(first.queueTotal, 150)
        XCTAssertEqual(first.queue.count, 40)
        XCTAssertEqual(second.queue.first?.id, "song-40")
        XCTAssertEqual(second.queueOffset, 40)
        fixture.audio.shutdown()
    }

    func testCancellationReleasesLibrarySelectionExactlyOnce() async throws {
        let fixture = try TemporaryDatabase()
        let library = CarPlayLibraryProvider(db: fixture.manager.dbPool, credentials: { nil }, cacheDirectories: [])
        let audio = AudioService(databaseManager: fixture.manager, carPlayLibrary: library)
        var completions = 0
        audio.playCarPlayLibrary(.albums, pageOffset: 0, index: 0, expectedId: "missing", sourceName: "Fixture") { result in
            completions += 1
            if case .success = result { XCTFail("A cancelled selection cannot apply playback") }
        }
        audio.cancelCarPlayRequests()
        XCTAssertEqual(completions, 1)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(audio.fullState())
        audio.shutdown()
    }

    func testLibraryQueueCarriesReplayGainAndCoverPreference() throws {
        var record = makeSongRecord("gain")
        record.coverArt = "song-cover"
        record.replayGainJson = "{\"trackGain\":-3,\"trackPeak\":0.9}"
        let song = record.toQueueSong(useAlbumCoverForSongs: true)
        XCTAssertEqual(song.coverArtId, record.albumId)
        XCTAssertEqual(song.replayGain?.trackGain, -3)
        XCTAssertEqual(song.replayGain?.trackPeak, 0.9)
        XCTAssertEqual(song.streamUrl, "aonsoku-media://stream?id=gain")
    }

    private func localSong(_ id: String, fixture: PlayerStoreTestFixture) throws -> QueueSong {
        let url = fixture.database.directory.appendingPathComponent("\(id).wav")
        try makeSilentWAVData().write(to: url)
        return QueueSong(id: id, title: id, artist: "Fixture", album: "Fixture", duration: 0.05,
            streamUrl: "aonsoku-media://stream?id=\(id)", cachedFileUri: url.absoluteString)
    }

    private func snapshot(_ audio: AudioService, offset: Int = 0, limit: Int = 100) async -> CarPlayPlaybackSnapshot {
        await withCheckedContinuation { continuation in
            audio.carPlaySnapshot(queueOffset: offset, queueLimit: limit) { continuation.resume(returning: $0) }
        }
    }
}
