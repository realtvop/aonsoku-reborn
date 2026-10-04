import XCTest
@testable import AonsokuNativePlugin

final class QueueTests: XCTestCase {
    func testSetContextQueueLoadsRequestedSongAndStartPosition() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate

        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 1,
            autoplay: true,
            startTime: 12.5
        )

        XCTAssertEqual(engine.currentSong?.id, "b")
        XCTAssertEqual(delegate.loads.first?.song.id, "b")
        XCTAssertEqual(delegate.loads.first?.autoplay, true)
        XCTAssertEqual(delegate.loads.first?.startTime, 12.5)
    }

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

    func testPreviousRestartsAfterThresholdBeforeChangingQueuePosition() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b")],
            currentIndex: 1,
            autoplay: false,
            startTime: nil
        )

        engine.skipToPrevious(currentTime: 4)

        XCTAssertEqual(engine.currentSong?.id, "b")
        XCTAssertEqual(delegate.seekedSongIds, ["b"])
    }

    func testReorderRetainsCurrentSongIdentityAndReportsContentChange() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a"), makeSong("b"), makeSong("c")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )

        engine.reorderContextQueue(fromIndex: 0, toIndex: 2)

        XCTAssertEqual(engine.contextSongs.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(engine.currentSong?.id, "a")
        XCTAssertEqual(engine.currentIndex, 2)
        XCTAssertEqual(delegate.contentReasons, ["queue-edit"])
    }

    func testQueueExhaustionDoesNotReloadCurrentSong() {
        let engine = NativeQueueEngine()
        let delegate = QueueDelegateSpy()
        engine.delegate = delegate
        engine.setContextQueue(
            songs: [makeSong("a")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        delegate.loads.removeAll()

        engine.skipToNext()

        XCTAssertEqual(delegate.exhaustionCount, 1)
        XCTAssertTrue(delegate.loads.isEmpty)
        XCTAssertEqual(engine.currentSong?.id, "a")
    }
}

private final class QueueDelegateSpy: NativeQueueEngineDelegate {
    struct Load {
        let song: QueueSong
        let autoplay: Bool
        let startTime: Double?
    }

    var loads: [Load] = []
    var advances: [(Int, String, QueueAdvanceReason)] = []
    var contentReasons: [String] = []
    var exhaustionCount = 0
    var seekedSongIds: [String] = []

    func queueEngine(
        _ engine: NativeQueueEngine,
        loadSong song: QueueSong,
        autoplay: Bool,
        startTime: Double?
    ) {
        loads.append(Load(song: song, autoplay: autoplay, startTime: startTime))
    }

    func queueEngine(
        _ engine: NativeQueueEngine,
        didAdvanceTo index: Int,
        songId: String,
        reason: QueueAdvanceReason
    ) {
        advances.append((index, songId, reason))
    }

    func queueEngine(_ engine: NativeQueueEngine, didChangeContents reason: String) {
        contentReasons.append(reason)
    }

    func queueEngineDidExhaustQueue(_ engine: NativeQueueEngine) {
        exhaustionCount += 1
    }

    func queueEngine(_ engine: NativeQueueEngine, seekToStart song: QueueSong) {
        seekedSongIds.append(song.id)
    }
}
