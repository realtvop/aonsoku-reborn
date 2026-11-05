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

/// What the realtime transport does when the machine woke or the network
/// moved to another interface. Connections are real, to a server on the
/// loopback interface; nothing sleeps the machine or leaves it.
@MainActor
final class CoordinationConnectionChangeTests: XCTestCase {
    /// A transport whose backoff is far longer than any test, so a request
    /// for a new ticket that arrives was made on purpose, not by the timer.
    private func makeRealtime() -> (CoordinationRealtime, ReconnectLog) {
        let realtime = CoordinationRealtime()
        realtime.reconnectPolicy = CoordinationReconnectPolicy(
            baseDelay: 60,
            maxDelay: 60
        )
        realtime.connectionValidationTimeout = 0.3
        let log = ReconnectLog()
        realtime.onReconnectNeeded = { attempt in
            log.requests.update { $0.append(attempt) }
        }
        realtime.onStateChange = { state, _ in
            log.states.update { $0.append(state) }
        }
        return (realtime, log)
    }

    private func connect(
        _ realtime: CoordinationRealtime,
        to server: LocalWebSocketServer,
        ticket: String
    ) async throws {
        try realtime.connect(
            wsUrl: server.url + "/v1/realtime",
            ticket: ticket,
            deviceId: "dev-1",
            capabilities: 0,
            protocolVersion: 1,
            lastSeq: 0,
            connectionId: 1
        )
        let connected = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            realtime.connectionStateDescription == "connected"
                && server.helloTickets.contains(ticket)
        }
        XCTAssertTrue(connected, "the transport never connected")
    }

    // MARK: No connection

    func testAConnectionChangeDoesNotWaitForAPendingBackoff() async {
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }
        // The last try failed and the next is a minute away.
        realtime.scheduleReconnect()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log.requests.read { $0 }, [])

        realtime.connectionMayHaveChanged()

        let asked = await waitForPlayerStoreTest {
            log.requests.read { $0 } == [1]
        }
        XCTAssertTrue(asked, "a new ticket was not asked for at once")
    }

    func testAConnectionChangeStartsTheBackoffOver() async {
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }
        // Several failed tries leave the next attempt number high.
        for _ in 0..<3 { realtime.scheduleReconnect() }

        realtime.connectionMayHaveChanged()

        let asked = await waitForPlayerStoreTest {
            !log.requests.read { $0 }.isEmpty
        }
        XCTAssertTrue(asked)
        XCTAssertEqual(log.requests.read { $0 }, [1])
    }

    func testRepeatedConnectionChangesAskForOneTicket() async {
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }

        for _ in 0..<5 { realtime.connectionMayHaveChanged() }
        let asked = await waitForPlayerStoreTest {
            !log.requests.read { $0 }.isEmpty
        }
        XCTAssertTrue(asked)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(log.requests.read { $0 }, [1])
    }

    func testAConnectionChangeAfterAnExplicitDisconnectDoesNothing() async {
        let (realtime, log) = makeRealtime()
        realtime.disconnect()
        let statesBefore = log.states.read { $0 }

        realtime.connectionMayHaveChanged()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(log.requests.read { $0 }, [])
        XCTAssertEqual(log.states.read { $0 }, statesBefore)
    }

    // MARK: A connection that is open

    func testAConnectionThatAnswersIsKept() async throws {
        let server = try LocalWebSocketServer()
        try server.start()
        defer { server.stop() }
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }
        try await connect(realtime, to: server, ticket: "ticket-1")

        realtime.connectionMayHaveChanged()
        let pinged = await waitForPlayerStoreTest { server.pingCount == 1 }
        XCTAssertTrue(pinged, "the connection was not checked")
        // Well past the time the answer had to arrive.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(realtime.connectionStateDescription, "connected")
        XCTAssertEqual(server.connectionCount, 1)
        XCTAssertEqual(server.closedConnectionCount, 0)
        XCTAssertEqual(log.requests.read { $0 }, [])
        XCTAssertFalse(log.states.read { $0 }.contains("disconnected"))
    }

    func testAConnectionThatDoesNotAnswerIsReplacedWithoutTheBackoff() async throws {
        let server = try LocalWebSocketServer()
        try server.start()
        defer { server.stop() }
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }
        try await connect(realtime, to: server, ticket: "ticket-1")
        // The machine slept: the socket is open, but nothing comes back.
        server.answersPings = false
        let asked = Date()

        realtime.connectionMayHaveChanged()

        let replaced = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            log.requests.read { $0 } == [1]
        }
        XCTAssertTrue(replaced, "the dead connection was never replaced")
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(asked),
            0.25,
            "the connection was dropped before it had time to answer"
        )
        XCTAssertEqual(realtime.connectionStateDescription, "disconnected")
        let closed = await waitForPlayerStoreTest { server.closedConnectionCount == 1 }
        XCTAssertTrue(closed, "the old connection was left open")
        XCTAssertTrue(log.states.read { $0 }.contains("disconnected"))
    }

    func testRepeatedChecksOfADeadConnectionReplaceItOnce() async throws {
        let server = try LocalWebSocketServer()
        try server.start()
        defer { server.stop() }
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }
        try await connect(realtime, to: server, ticket: "ticket-1")
        server.answersPings = false

        for _ in 0..<4 { realtime.connectionMayHaveChanged() }
        let replaced = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            !log.requests.read { $0 }.isEmpty
        }
        XCTAssertTrue(replaced)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(log.requests.read { $0 }, [1])
        XCTAssertEqual(server.connectionCount, 1)
    }

    func testDisconnectingDuringACheckCancelsIt() async throws {
        let server = try LocalWebSocketServer()
        try server.start()
        defer { server.stop() }
        let (realtime, log) = makeRealtime()
        try await connect(realtime, to: server, ticket: "ticket-1")
        server.answersPings = false
        realtime.connectionMayHaveChanged()
        let pinged = await waitForPlayerStoreTest { server.pingCount == 1 }
        XCTAssertTrue(pinged)

        realtime.disconnect()
        // Past the deadline the check would have acted at.
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(log.requests.read { $0 }, [])
        XCTAssertEqual(realtime.connectionStateDescription, "disconnected")
    }

    func testAConnectionBeingMadeIsReplacedAtOnce() async throws {
        let server = try LocalWebSocketServer()
        try server.start()
        defer { server.stop() }
        let (realtime, log) = makeRealtime()
        defer { realtime.disconnect() }
        // The ticket of a connection still being made may have expired
        // while the machine slept, so waiting for it would be pointless.
        try realtime.connect(
            wsUrl: server.url + "/v1/realtime",
            ticket: "ticket-1",
            deviceId: "dev-1",
            capabilities: 0,
            protocolVersion: 1,
            lastSeq: 0,
            connectionId: 1
        )
        XCTAssertEqual(realtime.connectionStateDescription, "connecting")

        realtime.connectionMayHaveChanged()

        let asked = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            log.requests.read { $0 } == [1]
        }
        XCTAssertTrue(asked)
    }

    // MARK: Leaks

    func testNothingOutlivesADisconnectAfterAConnectionChange() async throws {
        let server = try LocalWebSocketServer()
        try server.start()
        defer { server.stop() }
        server.answersPings = false
        weak var weakRealtime: CoordinationRealtime?
        do {
            let (realtime, _) = makeRealtime()
            weakRealtime = realtime
            // A deadline that is still pending when the transport goes away.
            realtime.connectionValidationTimeout = 30
            try await connect(realtime, to: server, ticket: "ticket-1")
            realtime.connectionMayHaveChanged()
            let pinged = await waitForPlayerStoreTest { server.pingCount == 1 }
            XCTAssertTrue(pinged)
            realtime.disconnect()
        }

        let released = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            weakRealtime == nil
        }

        XCTAssertTrue(released, "the transport is still alive after disconnect")
    }
}

private final class ReconnectLog: @unchecked Sendable {
    /// The attempt number of every request for a new ticket.
    let requests = LockedTestBox<[Int]>([])
    let states = LockedTestBox<[String]>([])
}
