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
}
