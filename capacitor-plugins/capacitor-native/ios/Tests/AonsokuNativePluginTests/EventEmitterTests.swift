import XCTest
@testable import AonsokuNativePlugin

final class EventEmitterTests: XCTestCase {
    func testSyncAndDataEventsKeepPublicNamesAndPayloads() {
        var events: [(String, [String: Any])] = []
        let emitter = EventEmitter { events.append(($0, $1)) }

        emitter.emitSyncStateChanged([
            "phase": "songs",
            "tier": "t3",
            "isSyncing": true,
        ])
        emitter.forceFlush()
        emitter.emitDataChanged(tables: ["artists", "albums"], tier: "t2")

        XCTAssertEqual(events.map(\.0), ["syncStateChanged", "dataChanged"])
        XCTAssertEqual(events[0].1["phase"] as? String, "songs")
        XCTAssertEqual(events[0].1["tier"] as? String, "t3")
        XCTAssertEqual(events[1].1["tables"] as? [String], ["artists", "albums"])
        XCTAssertEqual(events[1].1["tier"] as? String, "t2")
    }

    func testTerminalSyncPhasesFlushImmediately() {
        for phase in ["done", "error", "cancelled"] {
            var phases: [String] = []
            let emitter = EventEmitter { _, data in
                phases.append(data["phase"] as? String ?? "")
            }

            emitter.emitSyncStateChanged(["phase": phase, "isSyncing": false])

            XCTAssertEqual(phases, [phase])
        }
    }

    func testIntermediateSyncStatesCoalesceToLatestPayload() {
        var phases: [String] = []
        let emitter = EventEmitter { _, data in
            phases.append(data["phase"] as? String ?? "")
        }

        emitter.emitSyncStateChanged(["phase": "genres"])
        emitter.emitSyncStateChanged(["phase": "albums"])
        emitter.forceFlush()

        XCTAssertEqual(phases, ["albums"])
    }
}
