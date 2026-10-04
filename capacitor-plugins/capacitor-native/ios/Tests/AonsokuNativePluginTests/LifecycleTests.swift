import XCTest
@testable import AonsokuNativePlugin

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
