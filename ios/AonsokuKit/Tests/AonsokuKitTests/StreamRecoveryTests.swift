import AVFoundation
import XCTest
@testable import AonsokuKit

@MainActor
final class StreamRecoveryTests: XCTestCase {
    func testRepeatedPlayPreservesAnActiveReload() throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        let revision = fixture.recovery.revision
        var playError: AudioServiceError?
        fixture.audio.play { result in
            if case .failure(let error) = result { playError = error }
        }
        if let playError {
            throw XCTSkip("The simulator cannot activate its audio session: \(playError)")
        }

        XCTAssertEqual(fixture.recovery.state, .level2(attempt: 1))
        XCTAssertEqual(fixture.recovery.revision, revision)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    func testPlayReloadsAnItemThatFailedWhilePaused() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        let missingFile = fixture.database.directory.appendingPathComponent("missing.wav")
        fixture.audio.load(AudioLoadRequest(
            source: .stream(url: missingFile.absoluteString, songId: nil),
            metadata: AudioMetadata(duration: 30)
        )) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
        }
        let failed = await waitForPlayerStoreTest {
            fixture.player.currentItem?.status == .failed
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(fixture.recovery.state, .idle)

        var playError: AudioServiceError?
        fixture.audio.play { result in
            if case .failure(let error) = result { playError = error }
        }
        if let playError {
            throw XCTSkip("The simulator cannot activate its audio session: \(playError)")
        }

        XCTAssertEqual(fixture.recovery.state, .level2(attempt: 1))
        XCTAssertTrue(fixture.recovery.isMonitoringProgress)
    }

    func testFailureWhilePausedWaitsForAnExplicitPlay() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        let paused = await waitForPlayerStoreTest {
            fixture.audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(paused)

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: fixture.player.currentItem
        )

        XCTAssertEqual(fixture.recovery.state, .idle)
        XCTAssertTrue(fixture.scheduler.pending.isEmpty)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    func testPauseCancelsAnInFlightRecoverySeek() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream
        )
        fixture.scheduler.performNext()
        XCTAssertEqual(fixture.player.seekPositions, [12])

        fixture.audio.pause()
        fixture.player.finishSeek(success: true)

        XCTAssertEqual(fixture.player.playCount, 0)
        XCTAssertEqual(fixture.recovery.state, .idle)
    }

    func testPauseCancelsAnInFlightReloadSeek() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.scheduler.performNext()
        let sought = await waitForPlayerStoreTest { !fixture.player.seekPositions.isEmpty }
        XCTAssertTrue(sought)
        XCTAssertEqual(fixture.player.seekPositions, [12])

        fixture.audio.pause()
        fixture.player.finishSeek(success: true)

        XCTAssertEqual(fixture.player.playCount, 0)
        XCTAssertEqual(fixture.recovery.state, .idle)
    }

    func testFailedReloadSeekRetriesSavedPositionInsteadOfRestarting() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.scheduler.performNext()
        let sought = await waitForPlayerStoreTest { fixture.player.seekPositions.count == 1 }
        XCTAssertTrue(sought)
        fixture.player.finishSeek(success: false)
        XCTAssertEqual(fixture.recovery.state, .level2(attempt: 2))

        fixture.scheduler.performNext()
        let retried = await waitForPlayerStoreTest { fixture.player.seekPositions.count == 2 }
        XCTAssertTrue(retried)
        XCTAssertEqual(fixture.player.seekPositions, [12, 12])
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    private func makeFixture() throws -> (
        audio: AudioService,
        player: RecoveryTestPlayer,
        recovery: PlaybackRecoveryController,
        scheduler: ManualRecoveryScheduler,
        database: TemporaryDatabase
    ) {
        let database = try TemporaryDatabase()
        let url = database.directory.appendingPathComponent("recovery.wav")
        try makeSilentWAVData(duration: 30).write(to: url)
        let scheduler = ManualRecoveryScheduler()
        let recovery = PlaybackRecoveryController(recoveryScheduler: scheduler.schedule)
        let player = RecoveryTestPlayer()
        let audio = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            recoveryController: recovery,
            playerFactory: { item in
                player.replaceCurrentItem(with: item)
                return player
            }
        )
        audio.load(AudioLoadRequest(
            source: .nativeFile(uri: url.absoluteString, songId: nil),
            metadata: AudioMetadata(duration: 30)
        )) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
        }
        return (audio, player, recovery, scheduler, database)
    }
}

private final class ManualRecoveryScheduler {
    var pending: [DispatchWorkItem] = []

    func schedule(_ delay: TimeInterval, action: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        pending.append(work)
        return work
    }

    func performNext() {
        pending.removeAll { $0.isCancelled }
        guard !pending.isEmpty else { return XCTFail("No recovery action scheduled") }
        pending.removeFirst().perform()
    }
}

private final class RecoveryTestPlayer: AVPlayer {
    var playCount = 0
    var seekPositions: [Double] = []
    private var seekCompletion: (@Sendable (Bool) -> Void)?

    override func currentTime() -> CMTime {
        CMTime(seconds: 12, preferredTimescale: 600)
    }

    override func play() { playCount += 1 }

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        seekPositions.append(time.seconds)
        seekCompletion = completionHandler
    }

    func finishSeek(success: Bool) {
        let completion = seekCompletion
        seekCompletion = nil
        completion?(success)
    }
}
