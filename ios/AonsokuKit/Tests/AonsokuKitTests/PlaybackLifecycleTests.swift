import XCTest
@testable import AonsokuKit

final class PlaybackLifecycleTests: XCTestCase {
    func testInterruptionOnlyResumesPlaybackThatWasActiveBeforeItBegan() {
        var policy = AudioInterruptionResumePolicy()

        policy.interruptionBegan(wasPlaying: false)
        XCTAssertFalse(policy.interruptionEnded(shouldResume: true))

        policy.interruptionBegan(wasPlaying: true)
        XCTAssertTrue(policy.interruptionEnded(shouldResume: true))

        policy.interruptionBegan(wasPlaying: true)
        XCTAssertFalse(policy.interruptionEnded(shouldResume: false))
        XCTAssertFalse(policy.interruptionEnded(shouldResume: true))
    }

    func testRecoveryRejectsAnUnusableSavedSeekAndAcceptsAValidOne() {
        XCTAssertTrue(PlaybackRecoverySeekValidation.acceptsSavedPosition(
            seekFinished: true,
            savedPosition: 42,
            actualPosition: 42.5,
            loadedRangeContainsPosition: true,
            itemDuration: 100,
            metadataDuration: 100
        ))
        XCTAssertFalse(PlaybackRecoverySeekValidation.acceptsSavedPosition(
            seekFinished: true,
            savedPosition: 42,
            actualPosition: 0,
            loadedRangeContainsPosition: false,
            itemDuration: 100,
            metadataDuration: 100
        ))
        XCTAssertTrue(PlaybackRecoverySeekValidation.acceptsSavedPosition(
            seekFinished: true,
            savedPosition: 42,
            actualPosition: 42,
            loadedRangeContainsPosition: false,
            itemDuration: 100,
            metadataDuration: 100
        ))
        XCTAssertFalse(PlaybackRecoverySeekValidation.acceptsSavedPosition(
            seekFinished: true,
            savedPosition: 42,
            actualPosition: 42,
            loadedRangeContainsPosition: true,
            itemDuration: 120,
            metadataDuration: 100
        ))
        XCTAssertFalse(PlaybackRecoverySeekValidation.acceptsSavedPosition(
            seekFinished: false,
            savedPosition: 1,
            actualPosition: 0,
            loadedRangeContainsPosition: false,
            itemDuration: 0,
            metadataDuration: 100
        ))
    }

    func testExhaustedTailBypassesRecoveryAfterUnderreportedDuration() {
        XCTAssertTrue(QueueEndOfStreamPolicy.hasExhaustedReportedTail(
            position: 242,
            metadataDuration: 200,
            bufferedEnd: 240
        ))
        XCTAssertTrue(QueueEndOfStreamPolicy.hasExhaustedReportedTail(
            position: 240,
            metadataDuration: 200,
            bufferedEnd: 240
        ))
    }

    func testUnderreportedDurationDoesNotFinishWhileBufferedAudioRemains() {
        XCTAssertFalse(QueueEndOfStreamPolicy.hasExhaustedReportedTail(
            position: 220,
            metadataDuration: 200,
            bufferedEnd: 240
        ))
    }

    func testMidTrackAndUnknownTailsStillRequireRecovery() {
        for (position, metadataDuration, bufferedEnd) in [
            (42.0, 200.0, 40.0),
            (242, 0, 240),
            (242, .nan, 240),
            (242, .infinity, 240),
            (242, 200, 0),
            (242, 200, .nan),
            (242, 200, .infinity),
            (.nan, 200, 240),
            (.infinity, 200, 240),
            (242, 200, 150),
        ] {
            XCTAssertFalse(QueueEndOfStreamPolicy.hasExhaustedReportedTail(
                position: position,
                metadataDuration: metadataDuration,
                bufferedEnd: bufferedEnd
            ))
        }
    }

    func testQueueEndOfStreamFallbackOnlyAdvancesNearTheKnownEnd() {
        var tracker = QueueEndOfStreamTracker()
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(tracker.shouldAdvanceQueue(
            now: start,
            isQueueActive: true,
            isWaiting: true,
            bufferIsEmpty: true,
            position: 99.5,
            duration: 100
        ))
        XCTAssertFalse(tracker.shouldAdvanceQueue(
            now: start.addingTimeInterval(2.9),
            isQueueActive: true,
            isWaiting: true,
            bufferIsEmpty: true,
            position: 99.5,
            duration: 100
        ))
        XCTAssertTrue(tracker.shouldAdvanceQueue(
            now: start.addingTimeInterval(3),
            isQueueActive: true,
            isWaiting: true,
            bufferIsEmpty: true,
            position: 99.5,
            duration: 100
        ))

        XCTAssertFalse(tracker.shouldAdvanceQueue(
            now: start.addingTimeInterval(4),
            isQueueActive: true,
            isWaiting: false,
            bufferIsEmpty: true,
            position: 99.5,
            duration: 100
        ))

        for duration in [100.0, 0, .nan, .infinity] {
            XCTAssertFalse(tracker.shouldAdvanceQueue(
                now: start,
                isQueueActive: true,
                isWaiting: true,
                bufferIsEmpty: true,
                position: 42,
                duration: duration
            ))
            XCTAssertFalse(tracker.shouldAdvanceQueue(
                now: start.addingTimeInterval(30),
                isQueueActive: true,
                isWaiting: true,
                bufferIsEmpty: true,
                position: 42,
                duration: duration
            ))
        }
    }

    func testStopDoesNotPublishNaturalEndedEvent() throws {
        let database = try TemporaryDatabase()
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        let stopped = expectation(description: "stopped state published")
        let ended = expectation(description: "stop must not publish ended")
        ended.isInverted = true

        let token = service.subscribe { event in
            switch event {
            case .playbackStateChanged(.stopped, _):
                stopped.fulfill()
            case .ended:
                ended.fulfill()
            default:
                break
            }
        }

        service.stop()
        wait(for: [stopped, ended], timeout: 0.3)
        service.unsubscribe(token)
        service.shutdown()
    }

    func testPlaybackSnapshotCanBeReadFromABackgroundTask() async throws {
        let database = try TemporaryDatabase()
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )

        let snapshot = await Task.detached {
            service.playbackSnapshot()
        }.value

        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.currentTime, 0)
        XCTAssertEqual(snapshot.duration, 0)
        XCTAssertNil(snapshot.queue)
        service.shutdown()
    }
}
