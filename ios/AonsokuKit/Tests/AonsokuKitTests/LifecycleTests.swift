import XCTest
@testable import AonsokuKit

final class LifecycleTests: XCTestCase {
    func testLifecycleTransitionsAreOrderedAndIdempotent() {
        var gate = AppLifecycleTransitionGate()

        XCTAssertEqual(gate.phase, .launching)
        XCTAssertTrue(gate.transition(to: .active))
        XCTAssertFalse(gate.transition(to: .active))
        XCTAssertFalse(gate.transition(to: .foreground))
        XCTAssertTrue(gate.transition(to: .background))
        XCTAssertFalse(gate.transition(to: .background))
        XCTAssertTrue(gate.transition(to: .foreground))
        XCTAssertTrue(gate.transition(to: .active))
        XCTAssertTrue(gate.transition(to: .terminated))
        XCTAssertFalse(gate.transition(to: .active))
    }

    func testLifecycleRoutesEachAcceptedTransitionOnceInOrder() {
        var calls: [String] = []
        let lifecycle = AppLifecycleService(
            audio: AudioLifecycleActions(
                start: { calls.append("audio:start") },
                didEnterBackground: { calls.append("audio:background") },
                willEnterForeground: { calls.append("audio:foreground") },
                willTerminate: { calls.append("audio:terminate") },
                handleBackgroundSession: { _, _ in false }
            ),
            coordination: CoordinationLifecycleActions(
                didEnterBackground: { calls.append("coordination:background") },
                willEnterForeground: { calls.append("coordination:foreground") },
                willTerminate: { calls.append("coordination:terminate") }
            )
        )

        lifecycle.didFinishLaunching()
        lifecycle.didFinishLaunching()
        lifecycle.didEnterBackground()
        lifecycle.didEnterBackground()
        lifecycle.willEnterForeground()
        lifecycle.didBecomeActive()
        lifecycle.willTerminate()
        lifecycle.willTerminate()

        XCTAssertEqual(calls, [
            "audio:start",
            "audio:background",
            "coordination:background",
            "audio:foreground",
            "coordination:foreground",
            "coordination:terminate",
            "audio:terminate",
        ])
        XCTAssertEqual(lifecycle.phase, .terminated)
    }

    func testResignActiveSavesStateWithoutLeavingTheForeground() {
        var calls: [String] = []
        let lifecycle = AppLifecycleService(
            audio: AudioLifecycleActions(
                start: { calls.append("audio:start") },
                didEnterBackground: { calls.append("audio:background") },
                willEnterForeground: { calls.append("audio:foreground") },
                willTerminate: { calls.append("audio:terminate") },
                handleBackgroundSession: { _, _ in false },
                didResignActive: { calls.append("audio:resign") }
            ),
            coordination: CoordinationLifecycleActions(
                didEnterBackground: { calls.append("coordination:background") },
                willEnterForeground: { calls.append("coordination:foreground") },
                willTerminate: { calls.append("coordination:terminate") }
            )
        )

        // Before launch finishes there is nothing to save.
        lifecycle.didResignActive()
        lifecycle.didFinishLaunching()
        lifecycle.didResignActive()
        XCTAssertEqual(lifecycle.phase, .active)
        lifecycle.didBecomeActive()
        lifecycle.didResignActive()
        lifecycle.didEnterBackground()
        lifecycle.didResignActive()
        lifecycle.willTerminate()
        lifecycle.didResignActive()

        XCTAssertEqual(calls, [
            "audio:start",
            "audio:resign",
            "audio:resign",
            "audio:background",
            "coordination:background",
            "coordination:terminate",
            "audio:terminate",
        ])
    }

    func testSleepAndConnectionChangesReachOnlyARunningApp() {
        var calls: [String] = []
        let lifecycle = AppLifecycleService(
            audio: AudioLifecycleActions(
                start: { calls.append("audio:start") },
                didEnterBackground: { calls.append("audio:background") },
                willEnterForeground: { calls.append("audio:foreground") },
                willTerminate: { calls.append("audio:terminate") },
                handleBackgroundSession: { _, _ in false },
                willSleep: { calls.append("audio:sleep") },
                connectionMayHaveChanged: { calls.append("audio:connection") }
            ),
            coordination: CoordinationLifecycleActions(
                didEnterBackground: { calls.append("coordination:background") },
                willEnterForeground: { calls.append("coordination:foreground") },
                willTerminate: { calls.append("coordination:terminate") },
                connectionMayHaveChanged: { calls.append("coordination:connection") }
            )
        )

        // Nothing is running before launch finishes.
        lifecycle.systemWillSleep()
        lifecycle.connectionMayHaveChanged()
        XCTAssertTrue(calls.isEmpty)

        lifecycle.didFinishLaunching()
        lifecycle.systemWillSleep()
        lifecycle.connectionMayHaveChanged()
        lifecycle.connectionMayHaveChanged()
        // Sleeping and waking are not lifecycle transitions: a Mac stays in
        // the foreground through them.
        XCTAssertEqual(lifecycle.phase, .active)

        // In the background the transitions already do this work when the app
        // returns.
        lifecycle.didEnterBackground()
        lifecycle.systemWillSleep()
        lifecycle.connectionMayHaveChanged()
        lifecycle.willEnterForeground()
        XCTAssertEqual(lifecycle.phase, .foreground)
        lifecycle.connectionMayHaveChanged()
        lifecycle.didBecomeActive()
        lifecycle.willTerminate()
        lifecycle.systemWillSleep()
        lifecycle.connectionMayHaveChanged()

        XCTAssertEqual(calls, [
            "audio:start",
            "audio:sleep",
            "audio:connection",
            "coordination:connection",
            "audio:connection",
            "coordination:connection",
            "audio:background",
            "coordination:background",
            "audio:foreground",
            "coordination:foreground",
            "audio:connection",
            "coordination:connection",
            "coordination:terminate",
            "audio:terminate",
        ])
    }

    func testBackgroundSessionRoutingReturnsOwnershipAndCompletion() {
        var routedIdentifier: String?
        var completed = false
        let lifecycle = AppLifecycleService(
            audio: AudioLifecycleActions(
                start: {},
                didEnterBackground: {},
                willEnterForeground: {},
                willTerminate: {},
                handleBackgroundSession: { identifier, completion in
                    routedIdentifier = identifier
                    completion()
                    return true
                }
            ),
            coordination: CoordinationLifecycleActions(
                didEnterBackground: {},
                willEnterForeground: {},
                willTerminate: {}
            )
        )

        XCTAssertTrue(lifecycle.handleEventsForBackgroundURLSession(
            identifier: "downloads",
            completionHandler: { completed = true }
        ))
        XCTAssertEqual(routedIdentifier, "downloads")
        XCTAssertTrue(completed)
    }
}
