import XCTest
@testable import AonsokuNativePlugin

final class CoordinationTests: XCTestCase {
    func testHeartbeatEnvelopeHasVersionTypeAndUniqueMessageId() throws {
        let first = AonsokuNativeCoordinationPlugin.buildHeartbeatEnvelope(
            protocolVersion: 2
        )
        let second = AonsokuNativeCoordinationPlugin.buildHeartbeatEnvelope(
            protocolVersion: 2
        )

        XCTAssertEqual(first["version"] as? Int, 2)
        XCTAssertEqual(first["type"] as? String, "heartbeat")
        XCTAssertFalse(try XCTUnwrap(first["messageId"] as? String).isEmpty)
        XCTAssertNotEqual(first["messageId"] as? String, second["messageId"] as? String)
    }

    func testHelloEnvelopeCarriesResumeHandshake() {
        let envelope = AonsokuNativeCoordinationPlugin.buildHelloEnvelope(
            protocolVersion: 1,
            capabilities: 15,
            deviceId: "device-1",
            ticket: "ticket-1",
            lastSeq: 42
        )

        XCTAssertEqual(envelope["type"] as? String, "hello")
        XCTAssertEqual(envelope["protocolVersion"] as? Int, 1)
        XCTAssertEqual(envelope["capabilities"] as? Int, 15)
        XCTAssertEqual(envelope["deviceId"] as? String, "device-1")
        XCTAssertEqual(envelope["ticket"] as? String, "ticket-1")
        XCTAssertEqual(envelope["lastSeq"] as? Int, 42)
    }

    func testAcknowledgementAndHandoffEnvelopesPreserveFencingData() {
        let command = AonsokuNativeCoordinationPlugin.buildCommandAckEnvelope(
            protocolVersion: 1,
            messageId: "message-1"
        )
        XCTAssertEqual(command["messageId"] as? String, "message-1")
        XCTAssertEqual(command["type"] as? String, "command_ack")
        XCTAssertEqual(
            (command["result"] as? [String: Any])?["status"] as? String,
            "ok"
        )

        let relinquish = AonsokuNativeCoordinationPlugin.buildRelinquishAckEnvelope(
            protocolVersion: 1,
            transactionId: "tx-1",
            snapshot: ["songId": "song-1"]
        )
        XCTAssertEqual(relinquish["transactionId"] as? String, "tx-1")
        XCTAssertEqual(
            (relinquish["snapshot"] as? [String: Any])?["songId"] as? String,
            "song-1"
        )

        let failed = AonsokuNativeCoordinationPlugin.buildHandoffFailedEnvelope(
            protocolVersion: 1,
            transactionId: "tx-1",
            code: "source_pause_timeout"
        )
        XCTAssertEqual(failed["type"] as? String, "handoff_failed")
        XCTAssertEqual(failed["code"] as? String, "source_pause_timeout")
    }

    func testPlaybackSnapshotMapsQueueStateToProtocolShape() throws {
        let snapshot = try XCTUnwrap(
            AonsokuNativeCoordinationPlugin.buildPlaybackSnapshot(
                sessionId: "session-1",
                audioState: [
                    "currentSongId": "song-2",
                    "currentTime": 42.5,
                    "duration": 180.0,
                    "isPlaying": true,
                    "contextQueue": [
                        "songs": [["id": "song-1"], ["id": "song-2"]],
                        "currentIndex": 1,
                        "sourceId": ["type": "album", "id": "album-1"],
                        "sourceName": "Album One",
                    ],
                    "userQueue": [["id": "song-3"]],
                    "isInUserQueue": false,
                    "playedUserQueueHistory": [["id": "song-0"]],
                    "isShuffleActive": true,
                    "loopState": "all",
                ],
                sampledAtSeconds: 123,
                volume: 0.75
            )
        )

        XCTAssertEqual(snapshot["sessionId"] as? String, "session-1")
        XCTAssertEqual(snapshot["logicalPlaybackSessionId"] as? String, "session-1")
        XCTAssertEqual(snapshot["songId"] as? String, "song-2")
        XCTAssertEqual(snapshot["progressSeconds"] as? Double, 42.5)
        XCTAssertEqual(snapshot["durationSeconds"] as? Double, 180)
        XCTAssertEqual(snapshot["contextQueue"] as? [String], ["song-1", "song-2"])
        XCTAssertEqual(snapshot["contextIndex"] as? Int, 1)
        XCTAssertEqual(snapshot["sourceId"] as? String, "album:album-1")
        XCTAssertEqual(snapshot["userQueue"] as? [String], ["song-3"])
        XCTAssertEqual(snapshot["restorePrevious"] as? [String], ["song-0"])
        XCTAssertEqual(snapshot["repeat"] as? String, "all")
        XCTAssertEqual(snapshot["volume"] as? Double, 0.75)
        XCTAssertEqual(snapshot["historyWritten"] as? Bool, false)
        XCTAssertEqual(snapshot["nowPlayingSent"] as? Bool, false)
        XCTAssertEqual(snapshot["scrobbleSent"] as? Bool, false)
    }

    func testPlaybackSnapshotRequiresCurrentSong() {
        XCTAssertNil(AonsokuNativeCoordinationPlugin.buildPlaybackSnapshot(
            sessionId: "session-1",
            audioState: ["isPlaying": false],
            sampledAtSeconds: 123
        ))
    }

    func testJSONParserRejectsMalformedAndNonObjectPayloads() {
        XCTAssertEqual(JSONUtilities.parse("{\"a\":1}")?["a"] as? Int, 1)
        XCTAssertNil(JSONUtilities.parse("not json"))
        XCTAssertNil(JSONUtilities.parse("[1,2,3]"))
        XCTAssertNil(JSONUtilities.parse(""))
    }

    func testTicketURLPreservesQueryAndEscapesReservedCharacters() {
        XCTAssertEqual(
            CoordinationURL.buildTicketUrl("wss://host/v1/realtime", ticket: "abc"),
            "wss://host/v1/realtime?ticket=abc"
        )
        XCTAssertEqual(
            CoordinationURL.buildTicketUrl(
                "wss://host/v1/realtime?proto=1",
                ticket: "abc"
            ),
            "wss://host/v1/realtime?proto=1&ticket=abc"
        )
        let encoded = CoordinationURL.buildTicketUrl(
            "wss://host/v1/realtime",
            ticket: "a&b=c?d/e#f"
        )
        XCTAssertTrue(encoded.hasSuffix("ticket=a%26b%3Dc%3Fd%2Fe%23f"))
    }

    func testDedupCacheEvictsOldestAndTreatsRepeatAsIdempotent() {
        let cache = CoordinationDedup(max: 2)
        cache.mark("a")
        cache.mark("a")
        XCTAssertEqual(cache.size(), 1)
        cache.mark("b")
        cache.mark("c")
        XCTAssertFalse(cache.has("a"))
        XCTAssertTrue(cache.has("b"))
        XCTAssertTrue(cache.has("c"))
        cache.clear()
        XCTAssertEqual(cache.size(), 0)
    }

    func testSequenceTrackerOnlyAdvancesAndCanReset() {
        let tracker = CoordinationSeqTracker()
        tracker.observe(nil)
        tracker.observe(5)
        tracker.observe(3)
        XCTAssertEqual(tracker.get(), 5)
        tracker.observe(10)
        XCTAssertEqual(tracker.get(), 10)
        tracker.reset()
        XCTAssertEqual(tracker.get(), 0)
    }

    func testEnvelopeExtractionAcceptsProtocolNumericRepresentations() {
        XCTAssertEqual(CoordinationEnvelope.seq(["seq": 7]), 7)
        XCTAssertEqual(CoordinationEnvelope.seq(["seq": "12"]), 12)
        XCTAssertNil(CoordinationEnvelope.seq([:]))
        XCTAssertEqual(
            CoordinationEnvelope.messageId(["messageId": "abc"]),
            "abc"
        )
        XCTAssertNil(CoordinationEnvelope.messageId([:]))
        XCTAssertEqual(CoordinationEnvelope.type(["type": "command_ack"]), "command_ack")
        XCTAssertNil(CoordinationEnvelope.type([:]))
    }
}
