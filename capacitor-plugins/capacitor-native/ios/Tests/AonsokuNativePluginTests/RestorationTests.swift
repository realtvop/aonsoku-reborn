import XCTest
@testable import AonsokuNativePlugin

final class RestorationTests: XCTestCase {
    func testPlaybackRepositoryRoundTripsQueueAndProgress() throws {
        let database = try TemporaryDatabase()
        let source = NativeQueueEngine()
        source.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 1,
            autoplay: false,
            startTime: nil,
            sourceId: QueueSourceId(type: "album", id: "album-1"),
            sourceName: "Album One"
        )
        source.addToUserQueue(songs: [makeSong("u")], position: "last")
        source.setLoopState(.all)

        let repository = PlaybackStateRepository(db: database.manager.dbPool)
        try repository.save(PlaybackPersistState(from: source, currentTime: 42.5))
        guard let persisted = repository.load() else {
            return XCTFail("expected persisted playback state")
        }

        let restored = NativeQueueEngine()
        restored.restoreState(from: persisted)

        XCTAssertEqual(restored.contextSongs.map(\.id), ["a", "b"])
        XCTAssertEqual(restored.currentSong?.id, "b")
        XCTAssertEqual(restored.userQueue.map(\.id), ["u"])
        XCTAssertEqual(restored.loopState, .all)
        XCTAssertEqual(restored.sourceId, QueueSourceId(type: "album", id: "album-1"))
        XCTAssertEqual(persisted.currentTime, 42.5, accuracy: 0.001)
        XCTAssertTrue(restored.isRestored)
    }
}
