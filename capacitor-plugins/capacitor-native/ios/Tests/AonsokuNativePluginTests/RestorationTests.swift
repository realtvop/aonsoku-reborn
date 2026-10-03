import AVFoundation
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

    func testPlaybackRecoveryBeginsAndUserPauseCancelsIt() {
        let controller = PlaybackRecoveryController()
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate

        controller.triggerRecovery(
            currentTime: CMTime(seconds: 12, preferredTimescale: 600),
            generation: 4,
            sourceKind: .stream
        )

        XCTAssertEqual(controller.state, .level1(attempt: 1))
        XCTAssertEqual(delegate.didBeginCount, 1)
        XCTAssertEqual(delegate.bufferingStates, [true])

        controller.reportUserPause()
        XCTAssertEqual(controller.state, .idle)
    }
}

private final class RecoveryDelegateSpy: PlaybackRecoveryDelegate {
    var didBeginCount = 0
    var bufferingStates: [Bool] = []

    func recoverySeek(
        _ controller: PlaybackRecoveryController,
        to time: CMTime,
        generation: Int
    ) {}

    func recoveryReload(
        _ controller: PlaybackRecoveryController,
        generation: Int,
        savedPosition: CMTime
    ) {}

    func recoveryExhausted(
        _ controller: PlaybackRecoveryController,
        generation: Int
    ) {}

    func recoverySetBuffering(
        _ controller: PlaybackRecoveryController,
        isBuffering: Bool
    ) {
        bufferingStates.append(isBuffering)
    }

    func recoveryDidBegin(_ controller: PlaybackRecoveryController) {
        didBeginCount += 1
    }

    func recoveryDidSucceed(_ controller: PlaybackRecoveryController) {}
}
