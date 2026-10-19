import XCTest
@testable import AonsokuKit

@MainActor
final class CoordinationRealtimeTests: XCTestCase {
    func testFreshInstanceIsDisconnected() {
        let realtime = CoordinationRealtime()
        XCTAssertEqual(realtime.connectionStateDescription, "disconnected")
        XCTAssertNil(realtime.deviceId)
    }

    func testSendActiveControlCommandThrowsWhenNotConnected() {
        let realtime = CoordinationRealtime()
        XCTAssertThrowsError(
            try realtime.sendActiveControlCommand(["type": "play"]),
            "Should throw when no active control session"
        ) { error in
            guard let coordError = error as? CoordinationError else {
                XCTFail("Expected CoordinationError")
                return
            }
            XCTAssertEqual(coordError.code, CoordinationErrorCode.notConnected)
        }
    }

    func testRequestHandoffCandidateFromCacheThrowsWhenNoSnapshot() {
        let realtime = CoordinationRealtime()
        XCTAssertThrowsError(
            try realtime.requestHandoffCandidateFromCache(sourceDeviceId: "unknown-device"),
            "Should throw when no cached snapshot"
        ) { error in
            guard let coordError = error as? CoordinationError else {
                XCTFail("Expected CoordinationError")
                return
            }
            XCTAssertEqual(coordError.code, CoordinationErrorCode.snapshotExpired)
        }
    }

    func testGenerationAndSnapshotRevisionReturnNilForUnknownDevice() {
        let realtime = CoordinationRealtime()
        XCTAssertNil(realtime.generation(for: "unknown-device"))
        XCTAssertNil(realtime.snapshotRevision(for: "unknown-device"))
    }
}
