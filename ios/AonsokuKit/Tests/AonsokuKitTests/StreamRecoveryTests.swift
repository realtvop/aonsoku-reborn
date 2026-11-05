import AVFoundation
import XCTest
@testable import AonsokuKit

@MainActor
final class StreamRecoveryTests: XCTestCase {
    func testExhaustedQueueTailAdvancesWithoutSchedulingRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        try await prepareQueue(
            audio: fixture.audio, player: fixture.player, database: fixture.database
        )

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: fixture.player.currentItem
        )

        let advanced = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "second"
        }
        XCTAssertTrue(advanced)
        XCTAssertEqual(fixture.recovery.state, .idle)
        XCTAssertTrue(fixture.scheduler.pending.allSatisfy(\.isCancelled))
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
    }

    func testPendingRecoveryFinishesExhaustedTailBeforeReloading() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        try await prepareQueue(
            audio: fixture.audio, player: fixture.player, database: fixture.database
        )
        fixture.player.position = 8
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 2,
            sourceKind: .stream,
            requiresReload: true
        )
        fixture.player.position = 14
        fixture.scheduler.performNext()

        let advanced = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "second"
        }
        XCTAssertTrue(advanced)
        XCTAssertEqual(fixture.recovery.state, .idle)
        XCTAssertTrue(fixture.scheduler.pending.allSatisfy(\.isCancelled))
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
    }

    func testUnderreportedQueueDurationStillRecoversWithBufferedAudioAhead() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        try await prepareQueue(
            audio: fixture.audio, player: fixture.player, database: fixture.database
        )
        (fixture.player.currentItem as? RecoveryTestItem)?.bufferedEnd = 30

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: fixture.player.currentItem
        )

        XCTAssertEqual(fixture.audio.fullState()?.currentSongId, "first")
        XCTAssertEqual(fixture.recovery.state, .level2(attempt: 1))
        XCTAssertFalse(fixture.scheduler.pending.isEmpty)
    }

    func testExhaustedQueueTailRetainsRepeatOneAndProgressMonitoring() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        try await prepareQueue(
            audio: fixture.audio, player: fixture.player, database: fixture.database,
            repeatMode: .one
        )

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: fixture.player.currentItem
        )
        await flushPlayerCallbacks()

        let restarted = await waitForPlayerStoreTest {
            fixture.recovery.isMonitoringProgress
        }
        XCTAssertTrue(restarted)
        XCTAssertEqual(fixture.audio.fullState()?.currentSongId, "first")
        XCTAssertEqual(fixture.recovery.state, .idle)
        XCTAssertTrue(fixture.scheduler.pending.allSatisfy(\.isCancelled))
    }

    func testExhaustedQueueTailHonorsEndOfTrackSleep() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        try await prepareQueue(
            audio: fixture.audio, player: fixture.player, database: fixture.database
        )
        fixture.audio.setSleepTimer(seconds: 0, mode: "endOfTrack")

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: fixture.player.currentItem
        )

        XCTAssertEqual(fixture.audio.fullState()?.currentSongId, "first")
        XCTAssertEqual(fixture.audio.playbackSnapshot().state, .paused)
        XCTAssertFalse(fixture.recovery.isMonitoringProgress)
        XCTAssertTrue(fixture.scheduler.pending.allSatisfy(\.isCancelled))
    }

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

    // MARK: Sleep and network changes

    func testAConnectionChangeSkipsTheBackoffOfAStalledStream() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream
        )
        XCTAssertEqual(fixture.recovery.state, .level1(attempt: 1))
        let delaysBefore = fixture.scheduler.delays.count

        fixture.audio.connectionMayHaveChanged()

        // The same attempt, without its two-second wait.
        XCTAssertEqual(fixture.recovery.state, .level1(attempt: 1))
        XCTAssertEqual(Array(fixture.scheduler.delays.dropFirst(delaysBefore)), [0])
        fixture.scheduler.performNext()
        let sought = await waitForPlayerStoreTest { !fixture.player.seekPositions.isEmpty }
        XCTAssertTrue(sought)
        XCTAssertEqual(fixture.player.seekPositions, [12])
        fixture.player.finishSeek(success: true)
        let resumed = await waitForPlayerStoreTest { fixture.player.playCount == 1 }
        XCTAssertTrue(resumed)
    }

    func testAConnectionChangeLeavesHealthyPlaybackAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        let delaysBefore = fixture.scheduler.delays.count

        fixture.audio.connectionMayHaveChanged()
        fixture.audio.connectionMayHaveChanged()

        XCTAssertEqual(fixture.recovery.state, .idle)
        XCTAssertEqual(fixture.scheduler.delays.count, delaysBefore)
        XCTAssertTrue(fixture.player.seekPositions.isEmpty)
        XCTAssertEqual(fixture.player.playCount, 0)
    }

    func testAConnectionChangeNeverRestartsPlaybackThatAlreadyFailed() async throws {
        let fixture = try makeFixture()
        defer { fixture.audio.shutdown() }
        let errors = LockedTestBox<[String]>([])
        let token = fixture.audio.subscribe { event in
            if case .error(let code, _, _) = event { errors.update { $0.append(code) } }
        }
        defer { fixture.audio.unsubscribe(token) }
        fixture.recovery.triggerRecovery(
            currentTime: fixture.player.currentTime(),
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        // Two reloads, each cut off by its progress deadline.
        for reload in 1...2 {
            fixture.scheduler.performNext()
            let sought = await waitForPlayerStoreTest {
                fixture.player.seekPositions.count == reload
            }
            XCTAssertTrue(sought)
            fixture.scheduler.performNext()
        }
        XCTAssertEqual(fixture.recovery.state, .gaveUp)
        XCTAssertTrue(errors.read { $0 }.contains("recovery_failed"))
        XCTAssertEqual(fixture.audio.playbackSnapshot().state, .failed)
        let delaysBefore = fixture.scheduler.delays.count
        let seeksBefore = fixture.player.seekPositions.count
        let playsBefore = fixture.player.playCount

        // The user was told playback stopped, so only their play may start it
        // again, however much later the connection returns.
        fixture.audio.connectionMayHaveChanged()

        XCTAssertEqual(fixture.recovery.state, .gaveUp)
        XCTAssertEqual(fixture.scheduler.delays.count, delaysBefore)
        XCTAssertEqual(fixture.player.seekPositions.count, seeksBefore)
        XCTAssertEqual(fixture.player.playCount, playsBefore)
        XCTAssertEqual(fixture.audio.playbackSnapshot().state, .failed)
    }

    private func prepareQueue(
        audio: AudioService,
        player: RecoveryTestPlayer,
        database: TemporaryDatabase,
        repeatMode: AudioRepeatMode = .off
    ) async throws {
        let url = database.directory.appendingPathComponent("recovery.wav")
        let songs = ["first", "second"].map { id in
            QueueSong(
                id: id, title: id, artist: "Artist", album: "Album",
                duration: id == "first" ? 10 : 30,
                streamUrl: url.absoluteString,
                cachedFileUri: url.absoluteString
            )
        }
        audio.setContextQueue(
            songs: songs, currentIndex: 0, autoplay: false, repeatMode: repeatMode
        )
        let loaded = await waitForPlayerStoreTest {
            audio.playbackSnapshot().metadata.title == "first" &&
                audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(loaded)
        let item = try XCTUnwrap(player.currentItem as? RecoveryTestItem)
        item.bufferedEnd = 12
        player.position = 14
        var playError: AudioServiceError?
        audio.play { result in
            if case .failure(let error) = result { playError = error }
        }
        if let playError {
            throw XCTSkip("The simulator cannot activate its audio session: \(playError)")
        }
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
            // Exercise stream retries with local bytes. A native-file source
            // is deliberately rejected after repeated cache failures.
            source: .stream(url: url.absoluteString, songId: nil),
            metadata: AudioMetadata(duration: 30)
        )) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
        }
        return (audio, player, recovery, scheduler, database)
    }
}

private final class ManualRecoveryScheduler {
    var pending: [DispatchWorkItem] = []
    /// The delay of every action ever requested, in order.
    private(set) var delays: [TimeInterval] = []

    /// Actions that would still run.
    var livePendingCount: Int { pending.filter { !$0.isCancelled }.count }

    func schedule(_ delay: TimeInterval, action: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        delays.append(delay)
        pending.append(work)
        return work
    }

    func performNext() {
        pending.removeAll { $0.isCancelled }
        guard !pending.isEmpty else { return XCTFail("No recovery action scheduled") }
        pending.removeFirst().perform()
    }
}

/// Records what the recovery controller asks the player to do.
private final class RecoveryDelegateSpy: PlaybackRecoveryDelegate {
    private(set) var seeks: [Double] = []
    private(set) var reloads: [Double] = []
    private(set) var exhausted: [Int] = []
    private(set) var buffering: [Bool] = []
    private(set) var begins = 0
    private(set) var successes = 0

    func recoverySeek(_ controller: PlaybackRecoveryController, to time: CMTime, generation: Int) {
        seeks.append(time.seconds)
    }

    func recoveryReload(
        _ controller: PlaybackRecoveryController,
        generation: Int,
        savedPosition: CMTime
    ) {
        reloads.append(savedPosition.seconds)
    }

    func recoveryExhausted(_ controller: PlaybackRecoveryController, generation: Int) {
        exhausted.append(generation)
    }

    func recoverySetBuffering(_ controller: PlaybackRecoveryController, isBuffering: Bool) {
        buffering.append(isBuffering)
    }

    func recoveryDidBegin(_ controller: PlaybackRecoveryController) { begins += 1 }
    func recoveryDidSucceed(_ controller: PlaybackRecoveryController) { successes += 1 }
}

private final class RecoveryTestPlayer: AVPlayer {
    var position = 12.0
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
        CMTime(seconds: position, preferredTimescale: 600)
    }

    override func play() { playCount += 1 }

    override func seek(to time: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        position = time.seconds
        seekPositions.append(time.seconds)
        completionHandler(true)
    }

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
    var bufferedEnd = 0.0

    override var status: AVPlayerItem.Status { testStatus }
    override var duration: CMTime { CMTime(seconds: 30, preferredTimescale: 600) }
    override var loadedTimeRanges: [NSValue] {
        guard bufferedEnd > 0 else { return [] }
        return [NSValue(timeRange: CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: bufferedEnd, preferredTimescale: 600)
        ))]
    }

    func setStatus(_ status: AVPlayerItem.Status) {
        willChangeValue(forKey: "status")
        testStatus = status
        didChangeValue(forKey: "status")
    }
}

// MARK: - Sleep and network changes

/// A Mac keeps running through sleep and through the network moving to
/// another interface, so recovery has to notice for itself that what failed
/// before may work now. These tests drive the state machine by hand: no timer
/// runs and nothing waits for a connection.
@MainActor
final class ConnectionChangeRecoveryTests: XCTestCase {
    private let stalledAt = CMTime(seconds: 12, preferredTimescale: 600)

    private func makeController() -> (
        controller: PlaybackRecoveryController,
        scheduler: ManualRecoveryScheduler,
        delegate: RecoveryDelegateSpy
    ) {
        let scheduler = ManualRecoveryScheduler()
        let controller = PlaybackRecoveryController(recoveryScheduler: scheduler.schedule)
        let delegate = RecoveryDelegateSpy()
        controller.delegate = delegate
        return (controller, scheduler, delegate)
    }

    /// Fails both reloads of a level-2 recovery, each by its progress
    /// deadline, until the controller gives up.
    private func failEveryReload(_ scheduler: ManualRecoveryScheduler) {
        for _ in 0..<4 { scheduler.performNext() }
    }

    func testABackoffInProgressIsNotWaitedFor() {
        let (controller, scheduler, delegate) = makeController()
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .stream)
        let waiting = scheduler.pending[0]
        XCTAssertEqual(controller.state, .level1(attempt: 1))
        XCTAssertEqual(scheduler.delays, [2])
        XCTAssertTrue(delegate.seeks.isEmpty)

        controller.connectionMayHaveChanged(generation: 1)

        // The same attempt, now, not a second one.
        XCTAssertTrue(waiting.isCancelled)
        XCTAssertEqual(controller.state, .level1(attempt: 1))
        XCTAssertEqual(scheduler.delays, [2, 0])
        scheduler.performNext()
        XCTAssertEqual(delegate.seeks, [12])
        // Only the new attempt's progress deadline is left.
        XCTAssertEqual(scheduler.delays, [2, 0, 10])
        XCTAssertEqual(scheduler.livePendingCount, 1)
    }

    func testAnAttemptUnderWayIsMadeAgainWithoutUsingUpAnAttempt() {
        let (controller, scheduler, delegate) = makeController()
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .stream)
        scheduler.performNext()
        XCTAssertEqual(delegate.seeks, [12])
        let deadline = scheduler.pending[0]
        let staleRevision = controller.revision

        controller.connectionMayHaveChanged(generation: 1)

        XCTAssertTrue(deadline.isCancelled)
        XCTAssertEqual(controller.state, .level1(attempt: 1))
        // The attempt that was running can no longer report back.
        XCTAssertFalse(controller.isCurrentAttempt(generation: 1, revision: staleRevision))
        XCTAssertTrue(controller.isCurrentAttempt(generation: 1, revision: controller.revision))
        scheduler.performNext()
        XCTAssertEqual(delegate.seeks, [12, 12])
        XCTAssertEqual(scheduler.delays, [2, 10, 0, 10])
        XCTAssertEqual(controller.state, .level1(attempt: 1))
    }

    func testAReloadUnderWayIsMadeAgainWithoutUsingUpAnAttempt() {
        let (controller, scheduler, delegate) = makeController()
        controller.triggerRecovery(
            currentTime: stalledAt,
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        XCTAssertEqual(controller.state, .level2(attempt: 1))
        scheduler.performNext()
        XCTAssertEqual(delegate.reloads, [12])

        controller.connectionMayHaveChanged(generation: 1)

        XCTAssertEqual(controller.state, .level2(attempt: 1))
        scheduler.performNext()
        XCTAssertEqual(delegate.reloads, [12, 12])
        XCTAssertEqual(scheduler.delays, [3, 10, 0, 10])
        XCTAssertEqual(scheduler.livePendingCount, 1)
    }

    func testTheBackgroundDelayOfAReloadIsNotWaitedForEither() {
        let (controller, scheduler, delegate) = makeController()
        controller.setBackground(true)
        controller.triggerRecovery(
            currentTime: stalledAt,
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        XCTAssertEqual(scheduler.delays, [6])

        controller.connectionMayHaveChanged(generation: 1)
        scheduler.performNext()

        XCTAssertEqual(scheduler.delays, [6, 0, 20])
        XCTAssertEqual(delegate.reloads, [12])
    }

    func testRepeatedChangesLeaveASingleAttemptRunning() {
        let (controller, scheduler, delegate) = makeController()
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .stream)

        for _ in 0..<5 { controller.connectionMayHaveChanged(generation: 1) }
        XCTAssertEqual(scheduler.livePendingCount, 1)
        scheduler.performNext()
        XCTAssertEqual(delegate.seeks, [12])

        for _ in 0..<5 { controller.connectionMayHaveChanged(generation: 1) }
        XCTAssertEqual(scheduler.livePendingCount, 1)
        scheduler.performNext()
        XCTAssertEqual(delegate.seeks, [12, 12])
        XCTAssertEqual(controller.state, .level1(attempt: 1))
    }

    func testRadioRecoversLikeAnyOtherStream() {
        let (controller, scheduler, delegate) = makeController()
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .radio)
        XCTAssertEqual(scheduler.delays, [2])

        controller.connectionMayHaveChanged(generation: 1)
        scheduler.performNext()

        XCTAssertEqual(delegate.seeks, [12])
        XCTAssertEqual(controller.state, .level1(attempt: 1))
    }

    func testHealthyPlaybackIsLeftAlone() {
        let (controller, scheduler, delegate) = makeController()

        // Nothing has stalled.
        controller.connectionMayHaveChanged(generation: 0)
        controller.connectionMayHaveChanged(generation: 1)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(scheduler.delays.isEmpty)
        XCTAssertEqual(delegate.begins, 0)

        // Nor has a stall that already recovered.
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .stream)
        controller.reportProgress(
            at: CMTime(seconds: 13, preferredTimescale: 600),
            generation: 1
        )
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.successes, 1)
        let delays = scheduler.delays

        controller.connectionMayHaveChanged(generation: 1)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(scheduler.delays, delays)
        XCTAssertEqual(delegate.begins, 1)
    }

    func testLocalFilesAreLeftAlone() {
        let (controller, scheduler, _) = makeController()
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .nativeFile)
        XCTAssertEqual(controller.state, .level2(attempt: 1))
        let revision = controller.revision

        controller.connectionMayHaveChanged(generation: 1)

        XCTAssertEqual(controller.state, .level2(attempt: 1))
        XCTAssertEqual(controller.revision, revision)
        XCTAssertEqual(scheduler.delays, [3])
        XCTAssertEqual(scheduler.livePendingCount, 1)
    }

    func testAnotherSongsGenerationIsIgnored() {
        let (controller, scheduler, _) = makeController()
        controller.triggerRecovery(currentTime: stalledAt, generation: 1, sourceKind: .stream)
        let revision = controller.revision

        controller.connectionMayHaveChanged(generation: 2)
        controller.connectionMayHaveChanged(generation: 0)

        XCTAssertEqual(controller.state, .level1(attempt: 1))
        XCTAssertEqual(controller.revision, revision)
        XCTAssertEqual(scheduler.delays, [2])
    }

    func testRecoveryThatGaveUpStaysGivenUp() {
        let (controller, scheduler, delegate) = makeController()
        controller.triggerRecovery(
            currentTime: stalledAt,
            generation: 1,
            sourceKind: .stream,
            requiresReload: true
        )
        failEveryReload(scheduler)
        XCTAssertEqual(controller.state, .gaveUp)
        XCTAssertEqual(delegate.exhausted, [1])
        XCTAssertEqual(delegate.reloads, [12, 12])
        let delays = scheduler.delays
        let revision = controller.revision

        // The user was told playback stopped; only their play starts it again.
        controller.connectionMayHaveChanged(generation: 1)

        XCTAssertEqual(controller.state, .gaveUp)
        XCTAssertEqual(controller.revision, revision)
        XCTAssertEqual(scheduler.delays, delays)
        XCTAssertEqual(scheduler.livePendingCount, 0)
        XCTAssertEqual(delegate.exhausted, [1])
        XCTAssertEqual(delegate.begins, 1)
    }
}
