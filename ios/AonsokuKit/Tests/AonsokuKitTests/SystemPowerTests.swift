import Network
import XCTest
@testable import AonsokuKit

#if canImport(AppKit)
import AppKit
#endif

/// The machine's sleep and wake reach the app as notifications. These tests
/// post them by hand: nothing here ever puts the machine to sleep.
final class SystemPowerTests: XCTestCase {
    private let willSleep = Notification.Name("test.system-power.will-sleep")
    private let didWake = Notification.Name("test.system-power.did-wake")

    private func record(
        from source: some SystemPowerEventSource
    ) -> (events: LockedTestBox<[SystemPowerEvent]>, token: ObservationToken) {
        let events = LockedTestBox<[SystemPowerEvent]>([])
        let token = source.observe { event in events.update { $0.append(event) } }
        return (events, token)
    }

    private func makeSource(_ center: NotificationCenter) -> SystemPowerNotifications {
        SystemPowerNotifications(center: center, willSleep: willSleep, didWake: didWake)
    }

    func testSleepAndWakeNotificationsBecomeEventsInOrder() {
        let center = NotificationCenter()
        let (events, token) = record(from: makeSource(center))

        center.post(name: willSleep, object: nil)
        center.post(name: Notification.Name("test.system-power.unrelated"), object: nil)
        center.post(name: didWake, object: nil)
        center.post(name: willSleep, object: nil)

        XCTAssertEqual(events.read { $0 }, [.willSleep, .didWake, .willSleep])
        token.cancel()
    }

    func testCancellingEndsTheObservationAndMayBeRepeated() {
        let center = NotificationCenter()
        let (events, token) = record(from: makeSource(center))

        center.post(name: didWake, object: nil)
        token.cancel()
        token.cancel()
        center.post(name: didWake, object: nil)
        center.post(name: willSleep, object: nil)

        XCTAssertEqual(events.read { $0 }, [.didWake])
    }

    func testReleasingTheTokenEndsTheObservation() {
        let center = NotificationCenter()
        let events = LockedTestBox<[SystemPowerEvent]>([])
        var token: ObservationToken? = makeSource(center).observe { event in
            events.update { $0.append(event) }
        }

        center.post(name: didWake, object: nil)
        XCTAssertNotNil(token)
        token = nil
        center.post(name: didWake, object: nil)

        XCTAssertEqual(events.read { $0 }, [.didWake])
    }

    func testObservationsAreIndependent() {
        let center = NotificationCenter()
        let source = makeSource(center)
        let first = record(from: source)
        let second = record(from: source)

        center.post(name: didWake, object: nil)
        first.token.cancel()
        center.post(name: willSleep, object: nil)

        XCTAssertEqual(first.events.read { $0 }, [.didWake])
        XCTAssertEqual(second.events.read { $0 }, [.didWake, .willSleep])
        second.token.cancel()
    }

    func testTheEventsAreDeliveredOnTheThreadThatPostsThem() {
        let center = NotificationCenter()
        let delivered = expectation(description: "delivered")
        let observedMainThread = LockedTestBox<Bool?>(nil)
        let token = makeSource(center).observe { _ in
            observedMainThread.update { $0 = Thread.isMainThread }
            delivered.fulfill()
        }

        let wake = didWake
        DispatchQueue.global().async { center.post(name: wake, object: nil) }
        wait(for: [delivered], timeout: 2)

        XCTAssertEqual(observedMainThread.read { $0 }, false)
        token.cancel()
    }

    func testASourceWithoutEventsReportsNothing() {
        let (events, token) = record(from: NoPowerEvents())
        token.cancel()
        XCTAssertTrue(events.read { $0 }.isEmpty)
    }

    func testNetworkPathChangesAreOnlyAReasonToReconnectOnAMac() {
        #if canImport(UIKit)
        XCTAssertFalse(PlatformPower.reconnectsOnNetworkPathChange)
        #else
        XCTAssertTrue(PlatformPower.reconnectsOnNetworkPathChange)
        #endif
    }

    #if os(macOS)
    func testTheMacSourceListensToTheWorkspaceNotificationCenter() {
        let workspace = NSWorkspace.shared.notificationCenter
        let (events, token) = record(from: PlatformPower.makeSource(isTestProcess: false))

        // AppKit posts these to the workspace's own center, never the default
        // one.
        NotificationCenter.default.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertTrue(events.read { $0 }.isEmpty)

        workspace.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        workspace.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        XCTAssertEqual(events.read { $0 }, [.willSleep, .didWake])

        token.cancel()
        workspace.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        XCTAssertEqual(events.read { $0 }.count, 2)
    }

    func testAMacTestHostIgnoresTheMachineSleeping() {
        let workspace = NSWorkspace.shared.notificationCenter
        let (events, token) = record(from: PlatformPower.makeSource(isTestProcess: true))

        workspace.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        workspace.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        XCTAssertTrue(events.read { $0 }.isEmpty)
        token.cancel()
    }

    func testTheDefaultSourceOfATestProcessIsSilent() {
        // `swift test` and the app's own test bundle both run under XCTest.
        XCTAssertTrue(PlatformStorage.isRunningUnderXCTest)
        let workspace = NSWorkspace.shared.notificationCenter
        let (events, token) = record(from: PlatformPower.makeSource())

        workspace.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)

        XCTAssertTrue(events.read { $0 }.isEmpty)
        token.cancel()
    }
    #else
    func testIOSHasNoPowerEventsBecauseTheAppIsSuspended() {
        let (events, token) = record(from: PlatformPower.makeSource())
        token.cancel()
        XCTAssertTrue(events.read { $0 }.isEmpty)
    }
    #endif
}

final class NetworkPathChangeTests: XCTestCase {
    private func state(
        online: Bool = true,
        expensive: Bool = false,
        constrained: Bool = false,
        interfaces: Set<NWInterface.InterfaceType> = [.wifi]
    ) -> NetworkPathState {
        NetworkPathState(
            isOnline: online,
            isExpensive: expensive,
            isConstrained: constrained,
            interfaces: interfaces
        )
    }

    func testTheFirstUpdateOnlyDescribesThePath() {
        var detector = NetworkPathChangeDetector()
        XCTAssertFalse(detector.ingest(state()))

        var offline = NetworkPathChangeDetector()
        XCTAssertFalse(offline.ingest(state(online: false, interfaces: [])))
    }

    func testConnectivityComingBackIsAChange() {
        var detector = NetworkPathChangeDetector()
        _ = detector.ingest(state())
        XCTAssertFalse(detector.ingest(state(online: false, interfaces: [])))
        XCTAssertTrue(detector.ingest(state()))
        // Only the transition counts, not staying online.
        XCTAssertFalse(detector.ingest(state()))
    }

    func testSwitchingInterfacesWhileOnlineIsAChange() {
        var detector = NetworkPathChangeDetector()
        _ = detector.ingest(state(interfaces: [.wifi]))
        XCTAssertTrue(detector.ingest(state(interfaces: [.wiredEthernet])))
        XCTAssertTrue(detector.ingest(state(interfaces: [.wiredEthernet, .wifi])))
        XCTAssertFalse(detector.ingest(state(interfaces: [.wifi, .wiredEthernet])))
    }

    func testGoingOfflineAndStayingOfflineAreNotChanges() {
        var detector = NetworkPathChangeDetector()
        _ = detector.ingest(state())
        XCTAssertFalse(detector.ingest(state(online: false, interfaces: [])))
        XCTAssertFalse(detector.ingest(state(online: false, interfaces: [.cellular])))
        XCTAssertFalse(detector.ingest(state(online: false, interfaces: [])))
    }

    func testMeteredFlagsAloneAreNotAChange() {
        var detector = NetworkPathChangeDetector()
        _ = detector.ingest(state())
        XCTAssertFalse(detector.ingest(state(expensive: true)))
        XCTAssertFalse(detector.ingest(state(expensive: true, constrained: true)))
        XCTAssertFalse(detector.ingest(state()))
    }

    func testTheLockedDetectorKeepsOneHistoryAcrossThreads() {
        let detector = LockedPathChangeDetector()
        XCTAssertFalse(detector.ingest(state(online: false, interfaces: [])))

        let result = LockedTestBox<Bool?>(nil)
        let finished = expectation(description: "ingested")
        let online = state()
        DispatchQueue.global().async {
            result.update { $0 = detector.ingest(online) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(result.read { $0 }, true)
        XCTAssertFalse(detector.ingest(state()))
    }

    @MainActor
    func testThePublishedPathIsUpdatedBeforeTheChangeIsReported() {
        let monitor = NetworkMonitor(isOnline: false, isMetered: false)
        var reports: [(online: Bool, metered: Bool)] = []
        monitor.onPathChange = {
            reports.append((monitor.isOnline, monitor.isMetered))
        }

        monitor.publish(state(online: true), mayHaveBrokenConnections: false)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertTrue(reports.isEmpty)

        monitor.publish(
            state(online: true, expensive: true, interfaces: [.cellular]),
            mayHaveBrokenConnections: true
        )
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.online, true)
        XCTAssertEqual(reports.first?.metered, true)

        monitor.publish(state(online: false, interfaces: []), mayHaveBrokenConnections: false)
        XCTAssertFalse(monitor.isOnline)
        XCTAssertEqual(reports.count, 1)
    }
}
