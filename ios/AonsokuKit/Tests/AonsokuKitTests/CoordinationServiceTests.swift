import XCTest
@testable import AonsokuKit

@MainActor
final class CoordinationServiceTests: XCTestCase {
    private var tokenStore: TestTokenStore!
    private var transport: FakeRealtimeTransport!
    private var apiClient: FakeAPIClient!
    private var service: CoordinationService!

    private let config = CoordinationConfig(
        serverUrl: "https://coord.test",
        identityUrl: "https://music.test"
    )

    override func setUp() {
        super.setUp()
        tokenStore = TestTokenStore()
        transport = FakeRealtimeTransport()
        apiClient = FakeAPIClient()
        service = makeService()
    }

    private func makeService(
        credentials: ServerCredentials? = nil,
        ackTimeout: TimeInterval = 0.2
    ) -> CoordinationService {
        let apiClient = apiClient!
        return CoordinationService(
            tokenStore: tokenStore,
            realtime: transport,
            makeAPIClient: { _, _, _ in apiClient },
            credentials: { credentials },
            clientVersion: "2.0",
            ackTimeout: ackTimeout
        )
    }

    private func registeredTokens() -> CoordinationTokens {
        CoordinationTokens(
            deviceId: "dev-1",
            accountId: "acc-1",
            accessToken: "access",
            refreshToken: "refresh",
            accessTokenExpiresAt: 9_999_999_999_000
        )
    }

    /// Polls until `condition` holds, leaving the main actor free meanwhile.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func markConnected() {
        service.update { $0.connectionState = .connected }
    }

    // MARK: Start and connect

    func testStartLoadsConfigAndTokensThenConnects() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        apiClient.mockTicket = "ticket-1"

        service.start()
        await waitUntil { self.transport.connectCallCount > 0 }

        XCTAssertEqual(transport.connectCallCount, 1)
        XCTAssertEqual(transport.lastTicket, "ticket-1")
        XCTAssertEqual(transport.lastDeviceId, "dev-1")
        XCTAssertEqual(transport.lastCapabilities, CoordinationCapabilities.all)
        XCTAssertEqual(transport.lastProtocolVersion, 1)
        XCTAssertEqual(transport.lastWsUrl, "wss://coord.test/v1/realtime")
        XCTAssertEqual(service.state.config, config)
        XCTAssertEqual(service.state.deviceId, "dev-1")
        XCTAssertEqual(service.state.connectionState, .connected)
    }

    func testStartWithoutTokensDoesNotConnect() async {
        tokenStore.config = config

        service.start()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.connectCallCount, 0)
        XCTAssertEqual(service.state.config, config)
    }

    func testStartCalledTwiceConnectsOnce() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()

        service.start()
        service.start()
        await waitUntil { self.transport.connectCallCount > 0 }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.connectCallCount, 1)
    }

    func testStartAfterDisconnectReconnectsSavedRegistration() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()

        service.start()
        await waitUntil { self.transport.connectCallCount == 1 }
        service.disconnect()
        service.start()
        await waitUntil { self.transport.connectCallCount == 2 }

        XCTAssertEqual(transport.connectCallCount, 2)
        XCTAssertEqual(service.state.connectionState, .connected)
        XCTAssertEqual(service.state.deviceId, "dev-1")
    }

    func testConnectRegistersThisDeviceAndOpensTheSocket() async throws {
        apiClient.mockTokens = registeredTokens()
        apiClient.mockTicket = "ticket-2"
        let service = makeService(credentials: ServerCredentials(
            serverUrl: "https://music.test",
            username: "u",
            password: "p",
            authType: "password",
            protocolVersion: "1.16.1",
            serverType: "navidrome",
            fallbackUrl: nil
        ))

        try await service.connect(config: config, deviceName: "My Phone")

        XCTAssertEqual(apiClient.lastDeviceReg?.deviceName, "My Phone")
        XCTAssertEqual(apiClient.lastDeviceReg?.platform, "capacitor-ios")
        XCTAssertEqual(apiClient.lastDeviceReg?.clientVersion, "2.0")
        XCTAssertEqual(apiClient.lastDeviceReg?.capabilities, CoordinationCapabilities.all)
        XCTAssertEqual(apiClient.lastProof?.identityUrl, "https://music.test")
        XCTAssertEqual(tokenStore.config, config)
        XCTAssertEqual(service.state.deviceId, "dev-1")
        XCTAssertEqual(service.state.accountId, "acc-1")
        XCTAssertEqual(transport.lastTicket, "ticket-2")
    }

    func testConnectThrowsWithoutCredentials() async {
        do {
            try await service.connect(config: config, deviceName: "Phone")
            XCTFail("connect should throw")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.missingFields)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(apiClient.lastDeviceReg)
    }

    func testTransientTicketFailureSchedulesReconnect() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        apiClient.ticketError = CoordinationError(code: CoordinationErrorCode.internal)

        service.start()
        await waitUntil { self.transport.scheduleReconnectCount > 0 }

        XCTAssertEqual(transport.scheduleReconnectCount, 1)
        XCTAssertEqual(transport.connectCallCount, 0)
        XCTAssertEqual(service.state.connectionState, .reconnecting)
    }

    func testAuthenticationFailureDoesNotRetry() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        apiClient.ticketError = CoordinationError(code: CoordinationErrorCode.authenticationFailed)

        service.start()
        await waitUntil { self.service.state.connectionState == .error }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(service.state.connectionState, .error)
        XCTAssertEqual(service.state.lastError?.code, CoordinationErrorCode.authenticationFailed)
        XCTAssertEqual(transport.scheduleReconnectCount, 0)
        XCTAssertEqual(service.state.deviceId, "dev-1")
    }

    func testRevokedTicketForgetsTheRegistration() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        apiClient.ticketError = CoordinationError(code: CoordinationErrorCode.deviceRevoked)

        service.start()
        await waitUntil { self.service.state.deviceId == nil }
        await waitUntil { self.transport.resetSequenceCount > 0 }

        XCTAssertNil(tokenStore.tokens)
        XCTAssertNil(service.state.accountId)
        XCTAssertEqual(service.state.lastError?.code, CoordinationErrorCode.deviceRevoked)
        XCTAssertEqual(transport.disconnectCount, 1)
        XCTAssertEqual(transport.resetSequenceCount, 1)
        XCTAssertEqual(transport.scheduleReconnectCount, 0)
    }

    func testRevokedErrorEnvelopeForgetsTheRegistration() async {
        tokenStore.tokens = registeredTokens()
        service.update {
            $0.deviceId = "dev-1"
            $0.accountId = "acc-1"
        }

        transport.simulateEnvelope(
            #"{"type":"error","code":"device_revoked","reason":"revoked"}"#
        )

        XCTAssertNil(tokenStore.tokens)
        XCTAssertNil(service.state.deviceId)
        XCTAssertEqual(service.state.connectionState, .disconnected)
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    // MARK: Disconnect and reconnect

    func testDisconnectStopsAutomaticReconnectsUntilReconnectIsCalled() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        service.start()
        await waitUntil { self.transport.connectCallCount == 1 }

        service.disconnect()
        XCTAssertEqual(service.state.connectionState, .disconnected)
        XCTAssertEqual(transport.disconnectCount, 1)

        transport.onReconnectNeeded?(1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.connectCallCount, 1)

        await service.reconnect()
        XCTAssertEqual(transport.connectCallCount, 2)
        XCTAssertEqual(service.state.connectionState, .connected)
    }

    func testResetRegistrationClearsAccountTokensButKeepsConfig() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        service.start()
        await waitUntil { self.transport.connectCallCount == 1 }

        service.resetRegistration()
        service.start()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(tokenStore.tokens)
        XCTAssertEqual(tokenStore.config, config)
        XCTAssertNil(service.state.deviceId)
        XCTAssertNil(service.state.accountId)
        XCTAssertEqual(transport.connectCallCount, 1)
    }

    func testResetRegistrationRejectsAnInFlightTicket() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        let requested = expectation(description: "ticket requested")
        let gate = TicketGate()
        apiClient.ticketGate = gate
        apiClient.onTicketRequest = { requested.fulfill() }

        service.start()
        await fulfillment(of: [requested], timeout: 1)
        service.resetRegistration()
        await gate.resume(returning: "old-account-ticket")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.connectCallCount, 0)
        XCTAssertNil(service.state.deviceId)
        XCTAssertNil(service.state.accountId)
    }

    func testReconnectResumesFromTheLastSequence() async {
        tokenStore.config = config
        tokenStore.tokens = registeredTokens()
        transport.resumeSeq = 42

        service.start()
        await waitUntil { self.transport.connectCallCount == 1 }

        XCTAssertEqual(transport.lastConnectSeq, 42)
    }

    func testDisconnectFailsPendingCommands() async {
        let service = makeService(ackTimeout: 5)
        service.update { $0.connectionState = .connected }
        transport.mockGenerations = ["dev": 1]

        let send = Task { try await service.sendCommand(.play, to: "dev") }
        await waitUntil { !self.transport.sentCommands.isEmpty }
        service.disconnect()

        do {
            _ = try await send.value
            XCTFail("sendCommand should throw")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.notConnected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testForgetCurrentDeviceClearsTokensAndState() async {
        tokenStore.tokens = registeredTokens()
        service.update { state in
            state.deviceId = "dev-1"
            state.accountId = "acc-1"
            state.devices = [CoordinationDevice(id: "dev-1", name: "Phone", platform: "capacitor-ios")]
            state.controlledDeviceId = "dev-2"
        }

        await service.forgetCurrentDevice()
        await waitUntil { self.transport.resetSequenceCount > 0 }

        XCTAssertNil(tokenStore.tokens)
        XCTAssertNil(service.state.deviceId)
        XCTAssertNil(service.state.accountId)
        XCTAssertNil(service.state.controlledDeviceId)
        XCTAssertTrue(service.state.devices.isEmpty)
        XCTAssertEqual(transport.resetSequenceCount, 1)
    }

    // MARK: Commands

    func testSendCommandReturnsOkAck() async throws {
        markConnected()
        transport.mockGenerations = ["dev": 3]
        transport.ackResults = [#"{"status":"ok"}"#]

        let result = try await service.sendCommand(.seek(seconds: 12), to: "dev")

        XCTAssertEqual(result, .ok)
        XCTAssertEqual(transport.sentCommands.count, 1)
        XCTAssertEqual(transport.sentCommands.first?.targetDeviceId, "dev")
        XCTAssertEqual(transport.sentCommands.first?.expectedGeneration, 3)
        XCTAssertEqual(transport.sentCommands.first?.command["type"] as? String, "seek")
    }

    func testSendCommandReturnsErrorAck() async throws {
        markConnected()
        transport.mockGenerations = ["dev": 1]
        transport.ackResults = [#"{"status":"error","code":"target_offline","reason":"gone"}"#]

        let result = try await service.sendCommand(.play, to: "dev")

        XCTAssertEqual(result, .error(code: "target_offline", reason: "gone"))
    }

    func testStaleEpochRetriesOnceWithTheNewGeneration() async throws {
        markConnected()
        transport.mockGenerations = ["dev": 1]
        transport.generationsAfterFirstSend = ["dev": 2]
        transport.ackResults = [
            #"{"status":"error","code":"stale_epoch"}"#,
            #"{"status":"ok"}"#,
        ]

        let result = try await service.sendCommand(.next, to: "dev")

        XCTAssertEqual(result, .ok)
        XCTAssertEqual(transport.sentCommands.map(\.expectedGeneration), [1, 2])
        XCTAssertNotEqual(transport.sentCommands[0].messageId, transport.sentCommands[1].messageId)
    }

    func testSecondStaleEpochIsReturned() async throws {
        markConnected()
        transport.mockGenerations = ["dev": 1]
        transport.ackResults = [
            #"{"status":"error","code":"stale_epoch"}"#,
            #"{"status":"error","code":"stale_epoch"}"#,
        ]

        let result = try await service.sendCommand(.next, to: "dev")

        XCTAssertEqual(result, .error(code: "stale_epoch", reason: nil))
        XCTAssertEqual(transport.sentCommands.count, 2)
    }

    func testSendCommandTimesOut() async {
        let service = makeService(ackTimeout: 0.05)
        service.update { $0.connectionState = .connected }
        transport.mockGenerations = ["dev": 1]

        do {
            _ = try await service.sendCommand(.play, to: "dev")
            XCTFail("sendCommand should time out")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testLateAckAfterTimeoutIsIgnored() async {
        let service = makeService(ackTimeout: 0.05)
        service.update { $0.connectionState = .connected }
        transport.mockGenerations = ["dev": 1]

        _ = try? await service.sendCommand(.play, to: "dev")
        // Resuming the continuation twice would crash the test process.
        transport.onCommandAck?(transport.sentCommands.first?.messageId ?? "", #"{"status":"ok"}"#)
    }

    func testSendCommandWithoutSnapshotThrowsSnapshotExpired() async {
        markConnected()

        do {
            _ = try await service.sendCommand(.play, to: "unknown")
            XCTFail("sendCommand should throw")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.snapshotExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSendCommandWhileDisconnectedThrowsNotConnected() async {
        do {
            _ = try await service.sendCommand(.play, to: "dev")
            XCTFail("sendCommand should throw")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.notConnected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(transport.sentCommands.isEmpty)
    }

    func testControlSessionTracksTheControlledDevice() {
        service.beginControlSession(targetDeviceId: "dev-2")
        XCTAssertEqual(service.state.controlledDeviceId, "dev-2")
        XCTAssertEqual(transport.controlSessionTargets, ["dev-2"])
        XCTAssertEqual(transport.requestSnapshotsCount, 1)

        service.endControlSession()
        XCTAssertNil(service.state.controlledDeviceId)
        XCTAssertEqual(transport.controlSessionEndCount, 1)
    }

    func testHandoffRequestRequiresAConnection() {
        XCTAssertThrowsError(try service.requestHandoffCandidateFromCache(sourceDeviceId: "dev-2"))
        markConnected()
        XCTAssertNoThrow(try service.requestHandoffCandidateFromCache(sourceDeviceId: "dev-2"))
        XCTAssertEqual(transport.handoffSources, ["dev-2"])
    }

    // MARK: Envelopes and events

    func testDevicesChangedUpdatesState() {
        transport.simulateEnvelope(
            #"{"type":"devices_changed","devices":[{"id":"d1","name":"Phone","platform":"capacitor-ios"}]}"#
        )

        XCTAssertEqual(service.state.devices.map(\.id), ["d1"])
        XCTAssertNotNil(service.state.lastSyncAt)
    }

    func testSnapshotProjectionStoresAndRemoves() {
        transport.simulateEnvelope(
            #"{"type":"snapshot_projection","deviceId":"remote","generation":5,"snapshotRevision":2,"isOnline":true,"lastConfirmedAt":1000,"snapshot":{"sessionId":"s1","songId":"song1","isPlaying":true}}"#
        )

        let stored = service.state.deviceSnapshots["remote"]
        XCTAssertEqual(stored?.snapshot.songId, "song1")
        XCTAssertEqual(stored?.generation, 5)
        XCTAssertEqual(stored?.snapshotRevision, 2)
        XCTAssertEqual(stored?.isOnline, true)

        transport.simulateEnvelope(
            #"{"type":"snapshot_projection","deviceId":"remote","generation":6,"snapshotRevision":3,"isOnline":false}"#
        )

        XCTAssertNil(service.state.deviceSnapshots["remote"])
    }

    func testObserveDeliversStateAndEvents() {
        let recorder = EventRecorder()
        let observation = service.observe { recorder.events.append($0) }
        defer { observation.cancel() }

        transport.simulateEnvelope(
            #"{"type":"session_superseded","supersededGeneration":4,"transferredToDevice":"dev-2"}"#
        )
        transport.simulateEnvelope(#"{"type":"handoff_failed","transactionId":"tx","code":"source_changed"}"#)

        guard recorder.events.count == 3 else {
            return XCTFail("expected 3 events, got \(recorder.events)")
        }
        guard case .stateChanged = recorder.events[0] else {
            return XCTFail("the current state should arrive first")
        }
        guard case let .sessionSuperseded(generation, device) = recorder.events[1] else {
            return XCTFail("expected sessionSuperseded")
        }
        XCTAssertEqual(generation, 4)
        XCTAssertEqual(device, "dev-2")
        guard case let .handoffFailed(transactionId, code) = recorder.events[2] else {
            return XCTFail("expected handoffFailed")
        }
        XCTAssertEqual(transactionId, "tx")
        XCTAssertEqual(code, "source_changed")
    }

    func testCancelledObservationStopsDelivery() {
        let recorder = EventRecorder()
        let observation = service.observe { recorder.events.append($0) }
        observation.cancel()

        transport.simulateEnvelope(#"{"type":"capability_disabled","feature":"handoff"}"#)

        XCTAssertEqual(recorder.events.count, 1)
    }

    func testRemoteCommandExecutedIsForwarded() {
        let recorder = EventRecorder()
        let observation = service.observe { recorder.events.append($0) }
        defer { observation.cancel() }

        transport.onRemoteCommandExecuted?(["type": "seek", "seconds": 30], "dev-2")

        guard case let .remoteCommandExecuted(command, source) = recorder.events.last else {
            return XCTFail("expected remoteCommandExecuted")
        }
        XCTAssertEqual(command, .seek(seconds: 30))
        XCTAssertEqual(source, "dev-2")
    }
}

// MARK: - Fakes

private final class EventRecorder: @unchecked Sendable {
    var events: [CoordinationEvent] = []
}

private final class TestTokenStore: CoordinationTokenStoring, @unchecked Sendable {
    var tokens: CoordinationTokens?
    var config: CoordinationConfig?

    func loadTokens() -> CoordinationTokens? { tokens }
    func saveTokens(_ tokens: CoordinationTokens) { self.tokens = tokens }
    func clearTokens() { tokens = nil }
    func loadConfig() -> CoordinationConfig? { config }
    func saveConfig(_ config: CoordinationConfig) { self.config = config }
}

private final class FakeRealtimeTransport: CoordinationRealtimeTransport, @unchecked Sendable {
    struct SentCommand {
        let command: [String: Any]
        let targetDeviceId: String
        let expectedGeneration: Int
        let messageId: String?
    }

    var onStateChange: ((String) -> Void)?
    var onEnvelope: ((String) -> Void)?
    var onCommandAck: ((String, String) -> Void)?
    var onReconnectNeeded: ((Int) -> Void)?
    var onRemoteCommandExecuted: (([String: Any], String?) -> Void)?

    var connectCallCount = 0
    var lastWsUrl: String?
    var lastTicket: String?
    var lastDeviceId: String?
    var lastCapabilities: Int?
    var lastProtocolVersion: Int?
    var lastConnectSeq: Int?
    var disconnectCount = 0
    var scheduleReconnectCount = 0
    var resetSequenceCount = 0
    var requestSnapshotsCount = 0
    var controlSessionTargets: [String] = []
    var controlSessionEndCount = 0
    var handoffSources: [String] = []
    var resumeSeq = 0

    var mockGenerations: [String: Int] = [:]
    /// Installed after the first command is sent, to simulate a new epoch.
    var generationsAfterFirstSend: [String: Int]?
    /// Acknowledgements returned, in order, for each sent command.
    var ackResults: [String] = []
    var sentCommands: [SentCommand] = []

    func connect(
        wsUrl: String,
        ticket: String,
        deviceId: String,
        capabilities: Int,
        protocolVersion: Int,
        lastSeq: Int
    ) throws {
        XCTAssertTrue(Thread.isMainThread)
        connectCallCount += 1
        lastWsUrl = wsUrl
        lastTicket = ticket
        lastDeviceId = deviceId
        lastCapabilities = capabilities
        lastProtocolVersion = protocolVersion
        lastConnectSeq = lastSeq
        onStateChange?("connected")
    }

    func disconnect() {
        disconnectCount += 1
        onStateChange?("disconnected")
    }

    func scheduleReconnect() {
        XCTAssertTrue(Thread.isMainThread)
        scheduleReconnectCount += 1
    }

    func sendCommand(
        _ command: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int,
        messageId: String?
    ) {
        XCTAssertTrue(Thread.isMainThread)
        sentCommands.append(SentCommand(
            command: command,
            targetDeviceId: targetDeviceId,
            expectedGeneration: expectedGeneration,
            messageId: messageId
        ))
        if let next = generationsAfterFirstSend {
            mockGenerations = next
            generationsAfterFirstSend = nil
        }
        guard !ackResults.isEmpty, let messageId else { return }
        let result = ackResults.removeFirst()
        DispatchQueue.main.async {
            self.onCommandAck?(messageId, result)
        }
    }

    func sendControlSessionBegin(targetDeviceId: String) {
        controlSessionTargets.append(targetDeviceId)
    }

    func sendControlSessionEnd() { controlSessionEndCount += 1 }
    func requestSnapshots() { requestSnapshotsCount += 1 }

    func requestHandoffCandidateFromCache(sourceDeviceId: String) throws {
        handoffSources.append(sourceDeviceId)
    }

    func generation(for deviceId: String) -> Int? {
        XCTAssertTrue(Thread.isMainThread)
        return mockGenerations[deviceId]
    }

    var lastSeq: Int {
        XCTAssertTrue(Thread.isMainThread)
        return resumeSeq
    }

    func resetSequence() {
        resetSequenceCount += 1
        resumeSeq = 0
    }

    func didEnterBackground() {}
    func willEnterForeground() {}
    func willTerminate() {}

    func sendCommandFromNative(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: [String: Any]
    ) -> Bool { true }

    func publishNativePlaybackSnapshot(onlyWhenPlaying: Bool) -> Bool { true }

    func simulateEnvelope(_ json: String) {
        onEnvelope?(json)
    }
}

private final class FakeAPIClient: CoordinationAPIClient, @unchecked Sendable {
    var mockTokens: CoordinationTokens?
    var mockTicket = "ticket"
    var ticketError: CoordinationError?
    var mockDevices: [CoordinationDevice] = []
    var lastDeviceReg: CoordinationDeviceRegistration?
    var lastProof: CoordinationSubsonicProof?
    var ticketGate: TicketGate?
    var onTicketRequest: (() -> Void)?

    func register(
        proof: CoordinationSubsonicProof,
        device: CoordinationDeviceRegistration
    ) async throws -> CoordinationTokens {
        lastProof = proof
        lastDeviceReg = device
        guard let mockTokens else {
            throw CoordinationError(code: CoordinationErrorCode.internal)
        }
        return mockTokens
    }

    func webSocketTicket() async throws -> String {
        onTicketRequest?()
        if let ticketGate {
            return await ticketGate.wait()
        }
        if let ticketError { throw ticketError }
        return mockTicket
    }

    func listDevices() async throws -> [CoordinationDevice] { mockDevices }

    func renameDevice(id: String, name: String) async throws -> CoordinationDevice {
        CoordinationDevice(id: id, name: name, platform: "capacitor-ios")
    }

    func revokeDevice(id: String) async throws {}
    func deleteAccount() async throws {}
}

private actor TicketGate {
    private var result: String?
    private var continuation: CheckedContinuation<String, Never>?

    func wait() async -> String {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning result: String) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            self.result = result
        }
    }
}
