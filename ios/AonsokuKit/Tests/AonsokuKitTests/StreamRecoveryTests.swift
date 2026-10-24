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
        fixture.player.newItemStatus = .failed
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
        let sought = await waitForPlayerStoreTest { !fixture.player.seekPositions.isEmpty }
        XCTAssertTrue(sought)
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

    func testReloadWaitsForReadyItemBeforeSeekingSavedPosition() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.player.holdNewItems = true
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.scheduler.performNext()
        let replaced = await waitForPlayerStoreTest { fixture.player.heldItem != nil }
        XCTAssertTrue(replaced)
        XCTAssertEqual(fixture.player.currentItem?.status, .unknown)
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)

        fixture.player.prepareHeldItem()
        let sought = await waitForPlayerStoreTest { fixture.player.seekPositions.count == 1 }
        XCTAssertTrue(sought, String(describing: fixture.player.currentItem?.error))
        XCTAssertEqual(fixture.player.seekItemStatuses, [.readyToPlay])
        XCTAssertEqual(fixture.player.seekPositions, [12])
        (fixture.player.currentItem as? RecoveryTestItem)?.setStatus(.readyToPlay)
        await flushPlayerCallbacks()
        XCTAssertEqual(fixture.player.seekPositions, [12])
        fixture.player.finishSeek(success: true)
        XCTAssertEqual(fixture.player.playCount, 1)
        // A completed seek still needs playback progress to settle recovery.
        XCTAssertEqual(fixture.recovery.state, .level2(attempt: 1))
    }

    func testNeverReadyReloadExpiresAndIgnoresLateReadiness() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.player.holdNewItems = true
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.scheduler.performNext()
        let replaced = await waitForPlayerStoreTest { fixture.player.heldItem != nil }
        XCTAssertTrue(replaced)

        fixture.scheduler.performNext() // The first attempt's progress deadline.
        XCTAssertEqual(fixture.recovery.state, .level2(attempt: 2))
        let expiredItem = try XCTUnwrap(fixture.player.heldItem)
        fixture.player.prepareHeldItem()
        let ready = await waitForPlayerStoreTest { expiredItem.status == .readyToPlay }
        XCTAssertTrue(ready)
        await flushPlayerCallbacks()
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)

        fixture.scheduler.performNext() // Start the second reload.
        let retried = await waitForPlayerStoreTest { fixture.player.heldItem != nil }
        XCTAssertTrue(retried)
        fixture.scheduler.performNext() // A never-ready second item exhausts recovery.
        XCTAssertEqual(fixture.recovery.state, .gaveUp)
        fixture.player.prepareHeldItem()
        let settled = await waitForPlayerStoreTest {
            fixture.player.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(settled)
        await flushPlayerCallbacks()
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    func testPauseCancelsReloadWaitingForReadiness() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.player.holdNewItems = true
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.scheduler.performNext()
        let replaced = await waitForPlayerStoreTest { fixture.player.heldItem != nil }
        XCTAssertTrue(replaced)

        fixture.audio.pause()
        fixture.player.prepareHeldItem()
        let ready = await waitForPlayerStoreTest {
            fixture.player.currentItem?.status == .readyToPlay
        }
        XCTAssertTrue(ready)
        await flushPlayerCallbacks()
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
        XCTAssertEqual(fixture.player.playCount, 0)
        XCTAssertEqual(fixture.recovery.state, .idle)
    }

    func testFailedReloadItemRetriesWithoutSeeking() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        let missingFile = fixture.database.directory.appendingPathComponent("missing.wav")
        fixture.player.newItemStatus = .failed
        fixture.audio.load(AudioLoadRequest(
            source: .stream(url: missingFile.absoluteString, songId: nil),
            metadata: AudioMetadata(duration: 30)
        )) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
        }
        fixture.player.holdNewItems = true
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 2,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.scheduler.performNext()
        let replaced = await waitForPlayerStoreTest { fixture.player.heldItem != nil }
        XCTAssertTrue(replaced)
        fixture.player.prepareHeldItem()
        let retried = await waitForPlayerStoreTest {
            fixture.recovery.state == .level2(attempt: 2)
        }
        XCTAssertTrue(retried)
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    func testLoadWithStartTimeWaitsForReadiness() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.player.holdNewItems = true
        var completed = false
        let url = fixture.database.directory.appendingPathComponent("recovery.wav")
        fixture.audio.load(AudioLoadRequest(
            source: .nativeFile(uri: url.absoluteString, songId: nil),
            metadata: AudioMetadata(duration: 30),
            startTime: 9
        )) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            completed = true
        }
        XCTAssertEqual(fixture.player.currentItem?.status, .unknown)
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
        XCTAssertFalse(completed)

        fixture.player.prepareHeldItem()
        let sought = await waitForPlayerStoreTest { fixture.player.seekPositions.count == 1 }
        XCTAssertTrue(sought)
        XCTAssertEqual(fixture.player.seekItemStatuses, [.readyToPlay])
        XCTAssertEqual(fixture.player.seekPositions, [9])
        fixture.player.finishSeek(success: true)
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    private func flushPlayerCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
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
            playerItemFactory: { RecoveryTestItem(url: $0) },
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
    var seekItemStatuses: [AVPlayerItem.Status] = []
    var holdNewItems = false
    var newItemStatus: AVPlayerItem.Status = .readyToPlay
    private(set) var heldItem: AVPlayerItem?
    private var testItem: AVPlayerItem?
    private var seekCompletion: (@Sendable (Bool) -> Void)?

    override var currentItem: AVPlayerItem? { testItem }

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        testItem = item
        if holdNewItems, let item {
            heldItem = item
        } else {
            heldItem = nil
            (item as? RecoveryTestItem)?.setStatus(newItemStatus)
        }
    }

    func prepareHeldItem() {
        let item = heldItem
        heldItem = nil
        (item as? RecoveryTestItem)?.setStatus(newItemStatus)
    }

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
        if let status = currentItem?.status { seekItemStatuses.append(status) }
        seekCompletion = completionHandler
    }

    func finishSeek(success: Bool) {
        let completion = seekCompletion
        seekCompletion = nil
        completion?(success)
    }
}

// Control readiness through the same KVO boundary as AVFoundation, without
// depending on simulator media decoding or ever starting a real player.
private final class RecoveryTestItem: AVPlayerItem {
    private var testStatus: AVPlayerItem.Status = .unknown

    override var status: AVPlayerItem.Status { testStatus }
    override var duration: CMTime { CMTime(seconds: 30, preferredTimescale: 600) }

    func setStatus(_ status: AVPlayerItem.Status) {
        willChangeValue(forKey: "status")
        testStatus = status
        didChangeValue(forKey: "status")
    }
}
