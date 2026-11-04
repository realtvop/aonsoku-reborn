import Foundation
import XCTest
@testable import AonsokuKit

final class AudioRouteClassifierTests: XCTestCase {
    private let speakers: UInt32 = 1
    private let usbInterface: UInt32 = 2
    private let headphonesSource = AudioRouteClassifier.headphonesDataSource
    private let speakerSource = AudioRouteClassifier.fourCharacterCode("ispk")

    func testFourCharacterCodesMatchTheCoreAudioConstants() {
        XCTAssertEqual(AudioRouteClassifier.fourCharacterCode("hdpn"), 0x6864_706E)
        XCTAssertEqual(AudioRouteClassifier.fourCharacterCode("ispk"), 0x6973_706B)
        XCTAssertEqual(AudioRouteClassifier.headphonesDataSource, 0x6864_706E)
    }

    func testAnUnchangedOutputHasNoReason() {
        let output = snapshot(speakers, available: [speakers, usbInterface])

        XCTAssertNil(AudioRouteClassifier.reason(from: output, to: output))
    }

    func testAnotherDeviceComingOrGoingDoesNotChangeTheRoute() {
        let before = snapshot(speakers, available: [speakers])
        let after = snapshot(speakers, available: [speakers, usbInterface])

        XCTAssertNil(AudioRouteClassifier.reason(from: before, to: after))
        XCTAssertNil(AudioRouteClassifier.reason(from: after, to: before))
    }

    func testTheDefaultDeviceDisappearingIsAnUnavailableOutput() {
        let before = snapshot(usbInterface, available: [speakers, usbInterface])
        let after = snapshot(speakers, available: [speakers])

        XCTAssertEqual(
            AudioRouteClassifier.reason(from: before, to: after),
            .oldDeviceUnavailable
        )
    }

    func testLosingTheLastOutputIsAnUnavailableOutput() {
        let before = snapshot(usbInterface, available: [usbInterface])
        let after = snapshot(nil, available: [])

        XCTAssertEqual(
            AudioRouteClassifier.reason(from: before, to: after),
            .oldDeviceUnavailable
        )
    }

    func testANewDeviceBecomingTheDefaultIsANewDevice() {
        let before = snapshot(speakers, available: [speakers])
        let after = snapshot(usbInterface, available: [speakers, usbInterface])

        XCTAssertEqual(
            AudioRouteClassifier.reason(from: before, to: after),
            .newDeviceAvailable
        )
    }

    func testChoosingAnotherExistingDeviceIsAnOverride() {
        let both: Set<UInt32> = [speakers, usbInterface]

        XCTAssertEqual(
            AudioRouteClassifier.reason(
                from: snapshot(speakers, available: both),
                to: snapshot(usbInterface, available: both)
            ),
            .override
        )
    }

    func testHavingNoDefaultWhileTheDeviceStillExistsHasNoSuitableRoute() {
        XCTAssertEqual(
            AudioRouteClassifier.reason(
                from: snapshot(speakers, available: [speakers]),
                to: snapshot(nil, available: [speakers])
            ),
            .noSuitableRouteForCategory
        )
    }

    func testUnpluggingHeadphonesFromTheSameDeviceIsAnUnavailableOutput() {
        let before = snapshot(speakers, source: headphonesSource, available: [speakers])
        let after = snapshot(speakers, source: speakerSource, available: [speakers])

        XCTAssertEqual(
            AudioRouteClassifier.reason(from: before, to: after),
            .oldDeviceUnavailable
        )
    }

    func testPluggingHeadphonesIntoTheSameDeviceIsANewDevice() {
        let before = snapshot(speakers, source: speakerSource, available: [speakers])
        let after = snapshot(speakers, source: headphonesSource, available: [speakers])

        XCTAssertEqual(
            AudioRouteClassifier.reason(from: before, to: after),
            .newDeviceAvailable
        )
    }

    func testSwitchingBetweenOtherDataSourcesIsAConfigurationChange() {
        let lineOut = AudioRouteClassifier.fourCharacterCode("lout")
        let before = snapshot(speakers, source: lineOut, available: [speakers])
        let after = snapshot(speakers, source: speakerSource, available: [speakers])

        XCTAssertEqual(
            AudioRouteClassifier.reason(from: before, to: after),
            .routeConfigurationChange
        )
    }

    func testOnlyAnUnavailableOutputIsMeantToStopPlayback() {
        // `AudioService` pauses for `.oldDeviceUnavailable` and nothing else,
        // so every other change a headphone jack can cause must not match it.
        let reasons: [AudioRouteChangeReason?] = [
            AudioRouteClassifier.reason(
                from: snapshot(speakers, source: speakerSource, available: [speakers]),
                to: snapshot(speakers, source: headphonesSource, available: [speakers])
            ),
            AudioRouteClassifier.reason(
                from: snapshot(speakers, available: [speakers, usbInterface]),
                to: snapshot(usbInterface, available: [speakers, usbInterface])
            ),
        ]

        XCTAssertFalse(reasons.contains(.oldDeviceUnavailable))
    }

    func testReasonsPublishTheIOSRouteChangeVocabulary() {
        XCTAssertEqual(AudioRouteChangeReason.oldDeviceUnavailable.rawValue, "oldDeviceUnavailable")
        XCTAssertEqual(AudioRouteChangeReason.newDeviceAvailable.rawValue, "newDeviceAvailable")
        XCTAssertEqual(AudioRouteChangeReason.override.rawValue, "override")
        XCTAssertEqual(AudioRouteChangeReason.unknown.rawValue, "unknown")
    }

    private func snapshot(
        _ device: UInt32?,
        source: UInt32? = nil,
        available: Set<UInt32>
    ) -> AudioOutputSnapshot {
        AudioOutputSnapshot(deviceID: device, dataSource: source, availableDeviceIDs: available)
    }
}

final class AudioRouteMonitorTests: XCTestCase {
    private let speakers: UInt32 = 1
    private let usbInterface: UInt32 = 2

    func testDeliversReasonsOnTheGivenQueue() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let key = fixture.key
        let delivered = LockedTestBox<[(AudioRouteChangeReason, Bool)]>([])
        let token = fixture.monitor.start { reason in
            let onQueue = DispatchQueue.getSpecific(key: key) == true
            delivered.update { $0.append((reason, onQueue)) }
        }

        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(delivered.read { $0.map(\.0) }, [.oldDeviceUnavailable])
        XCTAssertEqual(delivered.read { $0.map(\.1) }, [true])
        token.cancel()
    }

    func testReportsReasonsInOrder() {
        let source = FakeOutputSource(output(speakers, [speakers]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.change(output(usbInterface, [speakers, usbInterface]))
        fixture.clock.advance(by: 5)
        source.change(output(speakers, [speakers, usbInterface]))
        fixture.clock.advance(by: 5)
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.newDeviceAvailable, .override])
        token.cancel()
    }

    func testADeviceRemovedSoonAfterTheUserSwitchedAwayCountsAsLost() {
        // The accepted cost of the race handling below: a device that stops
        // being the output and vanishes within the grace period is treated as
        // the output that went away.
        let source = FakeOutputSource(output(speakers, [speakers]))
        let fixture = MonitorFixture(source: source, gracePeriod: 2)
        let token = fixture.start()

        source.change(output(usbInterface, [speakers, usbInterface]))
        source.change(output(speakers, [speakers, usbInterface]))
        fixture.clock.advance(by: 1)
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(
            fixture.reasons,
            [.newDeviceAvailable, .override, .oldDeviceUnavailable]
        )
        token.cancel()
    }

    func testReportsAnUnavailableOutputWhenTheActiveDeviceIsRemoved() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.oldDeviceUnavailable])
        token.cancel()
    }

    func testIgnoresNotificationsThatLeaveTheRouteAlone() {
        let source = FakeOutputSource(output(speakers, [speakers]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.notify()
        source.change(output(speakers, [speakers, usbInterface]))
        source.notify()
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [])
        token.cancel()
    }

    func testReportsHeadphonesBeingUnpluggedFromTheBuiltInDevice() {
        let headphones = AudioRouteClassifier.headphonesDataSource
        let internalSpeakers = AudioRouteClassifier.fourCharacterCode("ispk")
        let source = FakeOutputSource(output(speakers, [speakers], source: headphones))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.change(output(speakers, [speakers], source: internalSpeakers))
        source.change(output(speakers, [speakers], source: headphones))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.oldDeviceUnavailable, .newDeviceAvailable])
        token.cancel()
    }

    func testTheDefaultMovingBeforeTheDeviceListUpdatesStillReportsTheLoss() {
        // Core Audio does not say which update arrives first. When the system
        // moves to the speakers before the removed device leaves the list,
        // the removal would otherwise look harmless.
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.change(output(speakers, [speakers, usbInterface]))
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.override, .oldDeviceUnavailable])
        token.cancel()
    }

    func testALateDeviceListUpdateIsNotAttributedToTheOldDevice() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source, gracePeriod: 2)
        let token = fixture.start()

        source.change(output(speakers, [speakers, usbInterface]))
        fixture.clock.advance(by: 3)
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.override])
        token.cancel()
    }

    func testALostDeviceIsReportedOnlyOnce() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.change(output(speakers, [speakers, usbInterface]))
        source.change(output(speakers, [speakers]))
        source.notify()
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.override, .oldDeviceUnavailable])
        token.cancel()
    }

    func testAStillAvailableDeviceIsNotReportedAsLost() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()

        source.change(output(speakers, [speakers, usbInterface]))
        source.change(output(usbInterface, [speakers, usbInterface]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [.override, .override])
        token.cancel()
    }

    func testCancellingTheTokenStopsListeningAndReporting() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let token = fixture.start()
        XCTAssertEqual(source.listenerCount, 1)

        token.cancel()
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(source.listenerCount, 0)
        XCTAssertEqual(fixture.reasons, [])
    }

    func testReleasingTheTokenStopsListening() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        func observeAndDrop() {
            let token = fixture.start()
            _ = token
        }

        observeAndDrop()

        XCTAssertEqual(source.listenerCount, 0)
    }

    func testTheTokenKeepsTheMonitorAlive() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let queue = DispatchQueue(label: "aonsoku.tests.route-monitor-lifetime")
        let reasons = LockedTestBox<[AudioRouteChangeReason]>([])
        let token = AudioRouteMonitor(source: source, queue: queue)
            .start { reason in reasons.update { $0.append(reason) } }

        source.change(output(speakers, [speakers]))
        queue.sync {}

        XCTAssertEqual(reasons.read { $0 }, [.oldDeviceUnavailable])
        token.cancel()
    }

    func testStartingAgainTakesANewBaseline() {
        let source = FakeOutputSource(output(usbInterface, [speakers, usbInterface]))
        let fixture = MonitorFixture(source: source)
        let first = fixture.start()
        first.cancel()
        source.change(output(speakers, [speakers]), notify: false)

        let second = fixture.start()
        source.change(output(speakers, [speakers]))
        fixture.flush()

        XCTAssertEqual(fixture.reasons, [])
        second.cancel()
    }

    private func output(
        _ device: UInt32?,
        _ available: Set<UInt32>,
        source: UInt32? = nil
    ) -> AudioOutputSnapshot {
        AudioOutputSnapshot(deviceID: device, dataSource: source, availableDeviceIDs: available)
    }
}

#if os(macOS)
final class CoreAudioOutputSourceTests: XCTestCase {
    func testSnapshotIncludesTheDefaultDeviceAmongTheAvailableOnes() {
        let snapshot = PlatformAudioOutput.makeSource().snapshot()

        // A machine without any output (a headless runner) has no default.
        if let device = snapshot.deviceID {
            XCTAssertTrue(snapshot.availableDeviceIDs.contains(device))
        } else {
            XCTAssertNil(snapshot.dataSource)
        }
    }

    func testListeningCanBeCancelledRepeatedlyAndIndependently() {
        let source = PlatformAudioOutput.makeSource()

        let first = source.startListening {}
        let second = source.startListening {}
        first.cancel()
        first.cancel()
        second.cancel()
    }

    func testReleasingTheTokenEndsTheListener() {
        let source = PlatformAudioOutput.makeSource()
        func listenAndDrop() {
            let token = source.startListening {}
            _ = token
        }

        listenAndDrop()
        listenAndDrop()
    }

    func testTheMacSessionWatchesOutputsAndNeverInterrupts() throws {
        let session = SystemAudioSession()

        XCTAssertTrue(session.pausesWhenOutputDisappears)
        try session.configure()
        try session.activate()
        session.deactivate()
        let interruptions = LockedTestBox(0)
        let interruption = session.observeInterruptions { _ in
            interruptions.update { $0 += 1 }
        }
        let routes = session.observeRouteChanges { _ in }
        interruption.cancel()
        routes.cancel()
        XCTAssertEqual(interruptions.read { $0 }, 0)
    }
}
#endif

// MARK: - Fixtures

private final class FakeOutputSource: AudioOutputSnapshotSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: AudioOutputSnapshot
    private var listeners: [UUID: @Sendable () -> Void] = [:]

    init(_ snapshot: AudioOutputSnapshot) {
        current = snapshot
    }

    var listenerCount: Int { lock.withLock { listeners.count } }

    func snapshot() -> AudioOutputSnapshot { lock.withLock { current } }

    func startListening(_ onChange: @escaping @Sendable () -> Void) -> ObservationToken {
        let id = UUID()
        lock.withLock { listeners[id] = onChange }
        return ObservationToken { [weak self] in
            self?.lock.withLock { self?.listeners[id] = nil }
        }
    }

    /// Moves the output as the system would, then tells the listeners.
    func change(_ snapshot: AudioOutputSnapshot, notify: Bool = true) {
        lock.withLock { current = snapshot }
        if notify { self.notify() }
    }

    func notify() {
        let all = lock.withLock { Array(listeners.values) }
        all.forEach { $0() }
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSinceReferenceDate: 1_000)

    var now: Date { lock.withLock { moment } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { moment = moment.addingTimeInterval(seconds) }
    }
}

private final class MonitorFixture {
    let key = DispatchSpecificKey<Bool>()
    let queue = DispatchQueue(label: "aonsoku.tests.route-monitor")
    let clock = ManualClock()
    let monitor: AudioRouteMonitor
    private let delivered = LockedTestBox<[AudioRouteChangeReason]>([])

    init(source: AudioOutputSnapshotSource, gracePeriod: TimeInterval = 2) {
        queue.setSpecific(key: key, value: true)
        let clock = clock
        monitor = AudioRouteMonitor(
            source: source,
            queue: queue,
            gracePeriod: gracePeriod,
            now: { clock.now }
        )
    }

    var reasons: [AudioRouteChangeReason] { delivered.read { $0 } }

    func start() -> ObservationToken {
        monitor.start { [delivered] reason in delivered.update { $0.append(reason) } }
    }

    /// Waits for everything the monitor has queued so far.
    func flush() { queue.sync {} }
}
