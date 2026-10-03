import XCTest
@testable import AonsokuNativePlugin

final class QueueTests: XCTestCase {
    func testUserQueueRunsBeforeRemainingContextAndCanNavigateBack() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b"), makeSong("c")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.addToUserQueue(songs: [makeSong("u1"), makeSong("u2")], position: "last")

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "u1")
        XCTAssertTrue(engine.isInUserQueue)

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "u2")

        engine.skipToNext()
        XCTAssertEqual(engine.currentSong?.id, "b")
        XCTAssertFalse(engine.isInUserQueue)

        engine.skipToPrevious(currentTime: 0)
        XCTAssertEqual(engine.currentSong?.id, "u2")
        XCTAssertTrue(engine.isInUserQueue)
    }

    func testRepeatOneStillConsumesPendingManualQueue() {
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [makeSong("a")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        engine.setLoopState(.one)
        engine.addToUserQueue(songs: [makeSong("u")], position: "next")

        engine.handleEnded()

        XCTAssertEqual(engine.currentSong?.id, "u")
        XCTAssertTrue(engine.isInUserQueue)
    }
}
