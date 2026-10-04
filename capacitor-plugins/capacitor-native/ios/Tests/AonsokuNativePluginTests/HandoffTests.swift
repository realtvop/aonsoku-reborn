import XCTest
@testable import AonsokuNativePlugin

final class HandoffTests: XCTestCase {
    func testHandoffSnapshotPreservesQueueOrderAndSource() throws {
        let snapshot = try XCTUnwrap(AonsokuNativeAudioPlugin.decodeHandoffSnapshot([
            "songId": "u1",
            "progressSeconds": 31.25,
            "contextQueue": ["a", "b"],
            "contextIndex": 0,
            "userQueue": ["u1", "u2"],
            "inUserQueue": true,
            "restorePrevious": ["old-u"],
            "shuffle": true,
            "repeat": "all",
            "sourceId": "playlist:mix:2026",
            "sourceName": "Mix",
            "volume": 0.6,
        ]))

        XCTAssertEqual(snapshot.contextQueue, ["a", "b"])
        XCTAssertEqual(snapshot.userQueue, ["u1", "u2"])
        XCTAssertEqual(snapshot.restorePrevious, ["old-u"])
        XCTAssertEqual(snapshot.songId, "u1")
        XCTAssertTrue(snapshot.inUserQueue)
        XCTAssertEqual(snapshot.repeatMode, .all)
        XCTAssertEqual(snapshot.sourceId, AudioQueueSource(type: "playlist", id: "mix:2026"))
        XCTAssertEqual(snapshot.progressSeconds, 31.25, accuracy: 0.001)
    }

    func testTargetReadyEnvelopeCarriesFencingState() {
        let envelope = AonsokuNativeCoordinationPlugin.buildTargetReadyEnvelope(
            protocolVersion: 1,
            transactionId: "tx",
            generation: 7,
            snapshotRevision: 12,
            sourceDeviceId: "source",
            sessionId: "session"
        )

        XCTAssertEqual(envelope["type"] as? String, "target_ready")
        XCTAssertEqual(envelope["generation"] as? Int, 7)
        XCTAssertEqual(envelope["snapshotRevision"] as? Int, 12)
        XCTAssertEqual(envelope["sessionId"] as? String, "session")
    }

    func testHandoffSnapshotSupportsEmptyContextWhileInUserQueue() throws {
        let snapshot = try XCTUnwrap(AonsokuNativeAudioPlugin.decodeHandoffSnapshot([
            "songId": "u1",
            "contextQueue": [],
            "userQueue": ["u1", "u2"],
            "inUserQueue": true,
        ]))

        XCTAssertTrue(snapshot.contextQueue.isEmpty)
        XCTAssertEqual(snapshot.userQueue, ["u1", "u2"])
        XCTAssertTrue(snapshot.inUserQueue)
    }

    func testHandoffSnapshotSupportsLegacySingleSongPayload() throws {
        let snapshot = try XCTUnwrap(AonsokuNativeAudioPlugin.decodeHandoffSnapshot([
            "songId": "song-1",
        ]))

        XCTAssertEqual(snapshot.contextQueue, ["song-1"])
        XCTAssertEqual(snapshot.contextIndex, 0)
        XCTAssertFalse(snapshot.inUserQueue)
    }

    func testHandoffSnapshotRejectsMissingCurrentSongId() {
        XCTAssertNil(AonsokuNativeAudioPlugin.decodeHandoffSnapshot([:]))
        XCTAssertNil(AonsokuNativeAudioPlugin.decodeHandoffSnapshot(["songId": ""]))
    }
}
