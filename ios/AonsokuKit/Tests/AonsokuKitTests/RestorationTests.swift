import AVFoundation
import XCTest
@testable import AonsokuKit

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

    func testStreamRecoveryEscalatesFromSeekToReloadAndExhaustion() {
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        let controller = PlaybackRecoveryController { delay, action in
            let work = DispatchWorkItem(block: action)
            scheduled.append((delay, work))
            return work
        }
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate

        controller.triggerRecovery(
            currentTime: CMTime(seconds: 19, preferredTimescale: 600),
            generation: 8,
            sourceKind: .stream
        )
        for expectedAttempt in 1 ... 3 {
            XCTAssertEqual(controller.state, .level1(attempt: expectedAttempt))
            scheduled.removeFirst().1.perform()
            XCTAssertEqual(
                delegate.seekPositions.last ?? -1,
                19,
                accuracy: 0.001
            )
            // No further KVO/stall event arrives after the seek. The attempt
            // watchdog must still advance recovery on its own.
            XCTAssertEqual(scheduled.first?.0, 10)
            scheduled.removeFirst().1.perform()
        }

        XCTAssertEqual(controller.state, .level2(attempt: 1))
        scheduled.removeFirst().1.perform()
        XCTAssertEqual(delegate.reloadPositions, [19])
        controller.reloadDidComplete(success: false, generation: 8)
        XCTAssertEqual(controller.state, .level2(attempt: 2))
        scheduled.removeAll { $0.1.isCancelled }
        scheduled.removeFirst().1.perform()
        controller.reloadDidComplete(success: false, generation: 8)

        XCTAssertEqual(controller.state, .gaveUp)
        XCTAssertEqual(delegate.exhaustedGenerations, [8])
        XCTAssertEqual(delegate.bufferingStates, [true, false])
        XCTAssertTrue(scheduled.allSatisfy { $0.1.isCancelled })
    }

    func testSuccessfulProgressCancelsPendingRecoveryAndClearsBuffering() {
        var scheduled: [DispatchWorkItem] = []
        let controller = PlaybackRecoveryController { _, action in
            let work = DispatchWorkItem(block: action)
            scheduled.append(work)
            return work
        }
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate

        controller.triggerRecovery(
            currentTime: CMTime(seconds: 4, preferredTimescale: 600),
            generation: 2,
            sourceKind: .nativeFile
        )
        XCTAssertEqual(controller.state, .level2(attempt: 1))

        controller.reportProgress(
            at: CMTime(seconds: 5, preferredTimescale: 600),
            generation: 2
        )
        scheduled.first?.perform()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.reloadPositions, [])
        XCTAssertEqual(delegate.didSucceedCount, 1)
        XCTAssertEqual(delegate.bufferingStates, [true, false])
    }

    func testSuccessfulReloadWithoutPlaybackProgressStillRetries() {
        var scheduled: [DispatchWorkItem] = []
        let controller = PlaybackRecoveryController { _, action in
            let work = DispatchWorkItem(block: action)
            scheduled.append(work)
            return work
        }
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate
        controller.triggerRecovery(currentTime: .zero, generation: 1, sourceKind: .nativeFile)
        scheduled.removeFirst().perform()
        controller.reloadDidComplete(success: true, generation: 1)
        scheduled.removeFirst().perform()

        XCTAssertEqual(controller.state, .level2(attempt: 2))
        controller.reportUserPause()
    }

    func testFailedItemSkipsSeekingAndReloadsAtTheSavedPosition() {
        var scheduled: [DispatchWorkItem] = []
        let controller = PlaybackRecoveryController { _, action in
            let work = DispatchWorkItem(block: action)
            scheduled.append(work)
            return work
        }
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate
        controller.triggerRecovery(
            currentTime: CMTime(seconds: 42, preferredTimescale: 600),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        scheduled.removeFirst().perform()

        XCTAssertEqual(delegate.seekPositions, [])
        XCTAssertEqual(delegate.reloadPositions, [42])
        controller.reportUserPause()
    }

    func testPausedAttemptCannotActOnANewRecoveryForTheSameItem() {
        var actions: [@Sendable () -> Void] = []
        let controller = PlaybackRecoveryController { _, action in
            actions.append(action)
            return DispatchWorkItem(block: action)
        }
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate
        controller.triggerRecovery(currentTime: .zero, generation: 1, sourceKind: .stream)
        let oldRevision = controller.revision
        controller.reportUserPause()
        controller.triggerRecovery(currentTime: .zero, generation: 1, sourceKind: .stream)
        actions.removeFirst()()

        XCTAssertFalse(controller.isCurrentAttempt(generation: 1, revision: oldRevision))
        XCTAssertEqual(delegate.seekPositions, [])
        controller.reportUserPause()
    }

    func testResumeBaselineDoesNotCountThePausedPositionAsProgress() {
        let controller = PlaybackRecoveryController()
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate
        let position = CMTime(seconds: 42, preferredTimescale: 600)
        controller.startProgressMonitoring(generation: 1, sourceKind: .stream, currentTime: position)
        controller.triggerRecovery(currentTime: position, generation: 1, sourceKind: .stream)
        controller.reportProgress(at: position, generation: 1)
        XCTAssertEqual(delegate.didSucceedCount, 0)

        controller.reportProgress(at: CMTime(seconds: 43, preferredTimescale: 600), generation: 1)
        XCTAssertEqual(delegate.didSucceedCount, 1)
        controller.reportUserPause()
    }
}

private final class RecoveryDelegateSpy: PlaybackRecoveryDelegate {
    var didBeginCount = 0
    var didSucceedCount = 0
    var bufferingStates: [Bool] = []
    var seekPositions: [Double] = []
    var reloadPositions: [Double] = []
    var exhaustedGenerations: [Int] = []

    func recoverySeek(
        _ controller: PlaybackRecoveryController,
        to time: CMTime,
        generation: Int
    ) {
        seekPositions.append(CMTimeGetSeconds(time))
    }

    func recoveryReload(
        _ controller: PlaybackRecoveryController,
        generation: Int,
        savedPosition: CMTime
    ) {
        reloadPositions.append(CMTimeGetSeconds(savedPosition))
    }

    func recoveryExhausted(
        _ controller: PlaybackRecoveryController,
        generation: Int
    ) {
        exhaustedGenerations.append(generation)
    }

    func recoverySetBuffering(
        _ controller: PlaybackRecoveryController,
        isBuffering: Bool
    ) {
        bufferingStates.append(isBuffering)
    }

    func recoveryDidBegin(_ controller: PlaybackRecoveryController) {
        didBeginCount += 1
    }

    func recoveryDidSucceed(_ controller: PlaybackRecoveryController) {
        didSucceedCount += 1
    }
}
