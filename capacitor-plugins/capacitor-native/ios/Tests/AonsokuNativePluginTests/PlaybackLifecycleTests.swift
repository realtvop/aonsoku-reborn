import XCTest
@testable import AonsokuNativePlugin

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

    func testStopDoesNotPublishNaturalEndedEvent() throws {
        let database = try TemporaryDatabase()
        let service = AudioService(databaseManager: database.manager)
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
}
