import Foundation

/// Native cross-device coordination: device registration, token refresh,
/// the realtime WebSocket, playback snapshot publication, remote control and
/// handoff. Behavior mirrors `src/coordination/{httpClient,manager,wsClient}.ts`
/// and the playback rules of the former Capacitor coordination plugin.
///
/// Keychain (`aonsoku-coordination`) and UserDefaults keys are shared with the
/// previous app so existing registrations survive the update.
///
/// Event handlers run on the main queue. `state` is safe to read from any
/// thread.
public final class CoordinationService: @unchecked Sendable {
    public static let shared = CoordinationService()

    private let lock = NSLock()
    private var currentState = CoordinationState()
    private var observers: [UUID: @Sendable (CoordinationEvent) -> Void] = [:]
    private let transport: CoordinationRealtimeTransport
    private let tokenStore: CoordinationTokenStoring
    private let makeAPIClient: @Sendable (
        String,
        CoordinationTokenStoring,
        @escaping @Sendable () -> CoordinationSubsonicProof?
    ) -> CoordinationAPIClient
    private let getCredentials: @Sendable () -> ServerCredentials?
    private let clientVersion: String
    private let ackTimeout: TimeInterval

    private var client: CoordinationAPIClient?
    private var started = false
    private var manualDisconnect = false
    private var reconnectGeneration: UInt64 = 0
    private var pendingAcks: [String: PendingAck] = [:]

    private struct PendingAck {
        let continuation: CheckedContinuation<CoordinationCommandResult, Error>
        let targetDeviceId: String
        let command: [String: Any]
        var retried: Bool
        var timeoutWorkItem: DispatchWorkItem
    }

    init(
        tokenStore: CoordinationTokenStoring = CoordinationKeychainTokenStore(),
        realtime: CoordinationRealtimeTransport? = nil,
        makeAPIClient: @escaping @Sendable (
            String,
            CoordinationTokenStoring,
            @escaping @Sendable () -> CoordinationSubsonicProof?
        ) -> CoordinationAPIClient = { CoordinationHTTPClient(baseURL: $0, tokenStore: $1, recoveryProof: $2) },
        credentials: @escaping @Sendable () -> ServerCredentials? = { AuthenticationService.shared.getCredentials() },
        clientVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        ackTimeout: TimeInterval = 10
    ) {
        self.tokenStore = tokenStore
        self.transport = realtime ?? CoordinationRealtime()
        self.makeAPIClient = makeAPIClient
        self.getCredentials = credentials
        self.clientVersion = clientVersion
        self.ackTimeout = ackTimeout

        setupRealtimeCallbacks()
    }

    // MARK: - State

    public var state: CoordinationState {
        lock.withLock { currentState }
    }

    /// Applies `mutate` and notifies observers when the state changed.
    /// Observers receive the state current at delivery time, so a delivery
    /// hopped from a background thread never overwrites a newer one.
    func update(_ mutate: (inout CoordinationState) -> Void) {
        let changed = lock.withLock { () -> Bool in
            var temp = currentState
            mutate(&temp)
            guard temp != currentState else { return false }
            currentState = temp
            return true
        }

        if changed {
            onMain { [weak self] in
                guard let self else { return }
                self.notifyObservers(.stateChanged(self.state))
            }
        }
    }

    private func emit(_ event: CoordinationEvent) {
        onMain { [weak self] in
            self?.notifyObservers(event)
        }
    }

    private func notifyObservers(_ event: CoordinationEvent) {
        let observerList = lock.withLock { Array(observers.values) }
        for observer in observerList {
            observer(event)
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// Subscribes to coordination events. The current state is delivered
    /// immediately as `.stateChanged`. Keep the observation alive; cancelling
    /// or releasing it unsubscribes.
    public func observe(
        _ handler: @escaping @Sendable (CoordinationEvent) -> Void
    ) -> CoordinationObservation {
        let id = UUID()
        let snapshot = lock.withLock { () -> CoordinationState in
            observers[id] = handler
            return currentState
        }
        onMain { handler(.stateChanged(snapshot)) }
        return CoordinationObservation { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.observers[id] = nil
            }
        }
    }

    // MARK: - Lifecycle

    /// Loads the saved config and tokens, then reconnects when this device is
    /// registered. Safe to call more than once.
    public func start() {
        let action = lock.withLock { () -> (load: Bool, reconnect: Bool) in
            if started {
                let reconnect = manualDisconnect && currentState.deviceId != nil
                manualDisconnect = false
                return (false, reconnect)
            }
            started = true
            manualDisconnect = false
            return (true, false)
        }

        if action.reconnect {
            Task { await reconnect(userInitiated: false) }
            return
        }
        guard action.load else { return }

        if let config = tokenStore.loadConfig() {
            update { $0.config = config }
            lock.withLock { client = makeClient(for: config) }
        }

        if let tokens = tokenStore.loadTokens() {
            update {
                $0.deviceId = tokens.deviceId
                $0.accountId = tokens.accountId
            }
            Task { await reconnect(userInitiated: false) }
        }
    }

    public func didEnterBackground() {
        transport.didEnterBackground()
    }

    public func willEnterForeground() {
        transport.willEnterForeground()
    }

    public func willTerminate() {
        transport.willTerminate()
    }

    // MARK: - Registration and connection

    /// Persists the coordination server and identity URLs.
    public func saveConfig(_ config: CoordinationConfig) {
        tokenStore.saveConfig(config)
        lock.withLock {
            reconnectGeneration &+= 1
            client = makeClient(for: config)
        }
        update { $0.config = config }
    }

    /// Saves `config`, proves the stored Subsonic credentials to the
    /// coordination server, registers this device and opens the realtime
    /// connection.
    public func connect(config: CoordinationConfig, deviceName: String) async throws {
        guard let creds = getCredentials() else {
            let error = CoordinationError(code: CoordinationErrorCode.missingFields, reason: "not signed in")
            update { $0.lastError = error }
            throw error
        }

        guard let proof = CoordinationSubsonicProof(identityUrl: config.identityUrl, credentials: creds) else {
            let error = CoordinationError(code: CoordinationErrorCode.missingFields, reason: "not signed in")
            update { $0.lastError = error }
            throw error
        }

        saveConfig(config)

        let apiClient = makeClient(for: config)
        let registrationGeneration = lock.withLock { () -> UInt64 in
            reconnectGeneration &+= 1
            manualDisconnect = false
            self.client = apiClient
            return reconnectGeneration
        }

        update { $0.connectionState = .authenticating }

        do {
            let device = CoordinationDeviceRegistration(
                deviceName: deviceName,
                platform: "capacitor-ios",
                clientVersion: clientVersion,
                capabilities: CoordinationCapabilities.all
            )
            let tokens = try await apiClient.register(proof: proof, device: device)
            guard acceptRegistrationAndUpdateState(
                tokens,
                generation: registrationGeneration,
                config: config,
                client: apiClient
            ) else {
                throw CoordinationError(code: CoordinationErrorCode.notConnected)
            }
            await reconnect(userInitiated: false)
        } catch let error as CoordinationError {
            guard isCurrentRegistration(
                generation: registrationGeneration,
                config: config,
                client: apiClient
            ) else { throw error }
            update {
                $0.connectionState = .error
                $0.lastError = error
            }
            throw error
        } catch {
            guard isCurrentRegistration(
                generation: registrationGeneration,
                config: config,
                client: apiClient
            ) else { throw error }
            let coordError = CoordinationError(code: CoordinationErrorCode.internal, reason: error.localizedDescription)
            update {
                $0.connectionState = .error
                $0.lastError = coordError
            }
            throw coordError
        }
    }

    private func isCurrentRegistration(
        generation: UInt64,
        config: CoordinationConfig,
        client expectedClient: CoordinationAPIClient
    ) -> Bool {
        lock.withLock {
            reconnectGeneration == generation
                && !manualDisconnect
                && currentState.config == config
                && client === expectedClient
        }
    }

    private func acceptRegistrationAndUpdateState(
        _ tokens: CoordinationTokens,
        generation: UInt64,
        config: CoordinationConfig,
        client expectedClient: CoordinationAPIClient
    ) -> Bool {
        let accepted = lock.withLock {
            guard reconnectGeneration == generation,
                  !manualDisconnect,
                  currentState.config == config,
                  client === expectedClient else { return false }
            tokenStore.saveTokens(tokens)
            currentState.deviceId = tokens.deviceId
            currentState.accountId = tokens.accountId
            currentState.lastError = nil
            return true
        }
        if accepted {
            onMain { [weak self] in
                guard let self else { return }
                self.notifyObservers(.stateChanged(self.state))
            }
        }
        return accepted
    }

    /// Opens the realtime connection with a fresh ticket when registered.
    public func reconnect() async {
        lock.withLock { manualDisconnect = false }
        await reconnect(userInitiated: true)
    }

    private func reconnect(userInitiated: Bool) async {
        let (generation, manualDisconnected, config, existingClient, deviceId) = lock.withLock {
            () -> (UInt64, Bool, CoordinationConfig?, CoordinationAPIClient?, String?) in
            reconnectGeneration &+= 1
            return (
                reconnectGeneration,
                manualDisconnect,
                currentState.config,
                self.client,
                currentState.deviceId
            )
        }

        guard !manualDisconnected, let deviceId else { return }

        var apiClient = existingClient
        guard let cfg = config else { return }

        if apiClient == nil {
            let createdClient = makeClient(for: cfg)
            guard lock.withLock({
                guard reconnectGeneration == generation,
                      !manualDisconnect,
                      currentState.config == cfg,
                      currentState.deviceId == deviceId else { return false }
                self.client = createdClient
                return true
            }) else { return }
            apiClient = createdClient
        }

        guard let apiClient else { return }

        do {
            let ticket = try await apiClient.webSocketTicket()
            guard isCurrentReconnect(
                generation: generation,
                config: cfg,
                client: apiClient,
                deviceId: deviceId
            ) else { return }
            let wsUrl = buildWSUrl(cfg.serverUrl)
            // The transport's state lives on the main thread.
            let transport = transport
            try await MainActor.run {
                guard self.isCurrentReconnect(
                    generation: generation,
                    config: cfg,
                    client: apiClient,
                    deviceId: deviceId
                ) else { return }
                try transport.connect(
                    wsUrl: wsUrl,
                    ticket: ticket,
                    deviceId: deviceId,
                    capabilities: CoordinationCapabilities.all,
                    protocolVersion: 1,
                    lastSeq: transport.lastSeq
                )
            }
        } catch let error as CoordinationError {
            guard isCurrentReconnect(
                generation: generation,
                config: cfg,
                client: apiClient,
                deviceId: deviceId
            ) else { return }
            if error.code == CoordinationErrorCode.deviceRevoked {
                handleDeviceRevoked(error)
            } else if error.code == CoordinationErrorCode.authenticationFailed {
                update {
                    $0.connectionState = .error
                    $0.lastError = error
                }
                emit(.error(error))
            } else {
                update {
                    $0.lastError = error
                    $0.connectionState = .reconnecting
                }
                onMain { [weak self] in
                    self?.transport.scheduleReconnect()
                }
            }
        } catch {
            guard isCurrentReconnect(
                generation: generation,
                config: cfg,
                client: apiClient,
                deviceId: deviceId
            ) else { return }
            update { $0.lastError = CoordinationError(code: CoordinationErrorCode.internal, reason: error.localizedDescription) }
        }
    }

    private func isCurrentReconnect(
        generation: UInt64,
        config: CoordinationConfig,
        client expectedClient: CoordinationAPIClient,
        deviceId: String
    ) -> Bool {
        lock.withLock {
            reconnectGeneration == generation
                && !manualDisconnect
                && currentState.config == config
                && currentState.deviceId == deviceId
                && client === expectedClient
        }
    }

    /// Closes the realtime connection and cancels automatic reconnects. The
    /// registration and tokens are kept.
    public func disconnect() {
        lock.withLock {
            manualDisconnect = true
            reconnectGeneration &+= 1
        }
        onMain { [weak self] in
            self?.transport.disconnect()
        }
        update { $0.connectionState = .disconnected }
        update { $0.controlledDeviceId = nil }

        let acks = lock.withLock { () -> [String: PendingAck] in
            let temp = pendingAcks
            pendingAcks.removeAll()
            return temp
        }

        for (_, ack) in acks {
            ack.timeoutWorkItem.cancel()
            ack.continuation.resume(throwing: CoordinationError(code: CoordinationErrorCode.notConnected))
        }
    }

    /// Clears this device's tokens and disconnects.
    public func forgetCurrentDevice() async {
        resetRegistration()
    }

    /// Clears account-bound registration without deleting the coordination
    /// server configuration. Used before another Subsonic account activates.
    func resetRegistration() {
        disconnect()
        tokenStore.clearTokens()
        onMain { [weak self] in
            self?.transport.resetSequence()
        }
        lock.withLock { self.client = nil }
        update {
            $0.deviceId = nil
            $0.accountId = nil
            $0.devices = []
            $0.deviceSnapshots = [:]
            $0.controlledDeviceId = nil
            $0.lastSyncAt = nil
            $0.lastError = nil
        }
    }

    /// Deletes the coordination account on the server, then forgets this
    /// device.
    public func deleteAccount() async throws {
        guard let client = lock.withLock({ self.client }) else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }

        try await client.deleteAccount()
        await forgetCurrentDevice()
    }

    // MARK: - Devices

    public func refreshDevices() async throws {
        guard let client = lock.withLock({ self.client }) else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }

        do {
            let devices = try await client.listDevices()
            update {
                $0.devices = devices
                $0.lastSyncAt = Date()
            }
        } catch let error as CoordinationError {
            if error.code == CoordinationErrorCode.deviceRevoked {
                handleDeviceRevoked(error)
            } else {
                update { $0.lastError = error }
            }
            throw error
        } catch {
            let coordError = CoordinationError(code: CoordinationErrorCode.internal, reason: error.localizedDescription)
            update { $0.lastError = coordError }
            throw coordError
        }
    }

    public func renameDevice(id: String, name: String) async throws {
        guard let client = lock.withLock({ self.client }) else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }

        _ = try await client.renameDevice(id: id, name: name)
        try await refreshDevices()
    }

    public func revokeDevice(id: String) async throws {
        guard let client = lock.withLock({ self.client }) else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }

        try await client.revokeDevice(id: id)

        if id == state.deviceId {
            await forgetCurrentDevice()
        } else {
            try await refreshDevices()
        }
    }

    /// Asks the server to rebroadcast every device's latest snapshot.
    public func requestSnapshots() {
        onMain { [weak self] in
            self?.transport.requestSnapshots()
        }
    }

    // MARK: - Remote control

    /// Starts driving `targetDeviceId`. Lock-screen and media-key commands are
    /// routed to that device until `endControlSession()`.
    public func beginControlSession(targetDeviceId: String) {
        update { $0.controlledDeviceId = targetDeviceId }
        onMain { [weak self] in
            self?.transport.sendControlSessionBegin(targetDeviceId: targetDeviceId)
            self?.transport.requestSnapshots()
        }
    }

    public func endControlSession() {
        update { $0.controlledDeviceId = nil }
        onMain { [weak self] in
            self?.transport.sendControlSessionEnd()
        }
    }

    /// Sends `command` to the controlled device and waits for its
    /// acknowledgement, retrying once on `stale_epoch`.
    @discardableResult
    public func sendActiveControlCommand(
        _ command: CoordinationRemoteCommand
    ) async throws -> CoordinationCommandResult {
        guard let controlledDeviceId = state.controlledDeviceId else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }
        return try await sendCommand(command, to: controlledDeviceId)
    }

    @discardableResult
    public func sendCommand(
        _ command: CoordinationRemoteCommand,
        to targetDeviceId: String
    ) async throws -> CoordinationCommandResult {
        guard state.isConnected else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }

        let transport = transport
        let generation = await MainActor.run { transport.generation(for: targetDeviceId) }

        guard let generation else {
            throw CoordinationError(code: CoordinationErrorCode.snapshotExpired, reason: "no snapshot for target")
        }

        let messageId = UUID().uuidString
        let result: CoordinationCommandResult = try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self else {
                continuation.resume(throwing: CoordinationError(code: CoordinationErrorCode.internal))
                return
            }

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                let wasRemoved = self?.lock.withLock {
                    self?.pendingAcks.removeValue(forKey: messageId)
                } != nil
                if wasRemoved {
                    continuation.resume(throwing: CoordinationError(code: CoordinationErrorCode.timeout))
                }
            }

            self.lock.withLock {
                self.pendingAcks[messageId] = PendingAck(
                    continuation: continuation,
                    targetDeviceId: targetDeviceId,
                    command: command.jsonObject,
                    retried: false,
                    timeoutWorkItem: timeoutWorkItem
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + self.ackTimeout, execute: timeoutWorkItem)

            self.onMain { [weak self] in
                self?.transport.sendCommand(command.jsonObject, targetDeviceId: targetDeviceId, expectedGeneration: generation, messageId: messageId)
            }
        }

        return result
    }

    // MARK: - Handoff

    /// Requests that `sourceDeviceId`'s playback continue on this device,
    /// using the cached generation and snapshot revision. The outcome arrives
    /// as `.handoffCommitted` or `.handoffFailed`.
    @MainActor
    public func requestHandoffCandidateFromCache(sourceDeviceId: String) throws {
        guard state.isConnected else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected)
        }
        try transport.requestHandoffCandidateFromCache(sourceDeviceId: sourceDeviceId)
    }

    /// Send a command from the active audio service to a remote device.
    /// Main-thread only. Returns true if sent, false if coordination is not connected.
    func sendCommandFromActive(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: [String: Any]
    ) -> Bool {
        transport.sendCommandFromNative(
            targetDeviceId: targetDeviceId,
            expectedGeneration: expectedGeneration,
            command: command
        )
    }

    /// Publish a playback snapshot from the active audio service.
    /// Main-thread only. Returns true if sent, false otherwise.
    func publishSnapshotFromActiveAudioState() -> Bool {
        transport.publishNativePlaybackSnapshot(onlyWhenPlaying: false)
    }

    // MARK: - Private Helpers

    private func makeClient(for config: CoordinationConfig) -> CoordinationAPIClient {
        makeAPIClient(config.serverUrl, tokenStore) { [weak self] in
            guard let self else { return nil }
            let cfg = self.state.config
            guard let cfg else { return nil }
            guard let creds = self.getCredentials() else { return nil }
            return CoordinationSubsonicProof(identityUrl: cfg.identityUrl, credentials: creds)
        }
    }

    private func buildWSUrl(_ serverUrl: String) -> String {
        let trimmed = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let wsScheme = trimmed.hasPrefix("https") ? "wss" : "ws"
        let baseUrl = trimmed.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        return wsScheme + "://" + baseUrl + "/v1/realtime"
    }

    private func setupRealtimeCallbacks() {
        transport.onStateChange = { [weak self] state in
            self?.handleRealtimeStateChange(state)
        }

        transport.onReconnectNeeded = { [weak self] _ in
            Task { await self?.reconnect(userInitiated: false) }
        }

        transport.onEnvelope = { [weak self] json in
            self?.handleRealtimeEnvelope(json)
        }

        transport.onCommandAck = { [weak self] messageId, resultJson in
            self?.handleCommandAck(messageId: messageId, resultJson: resultJson)
        }

        transport.onRemoteCommandExecuted = { [weak self] commandDict, sourceDeviceId in
            self?.handleRemoteCommandExecuted(commandDict, sourceDeviceId: sourceDeviceId)
        }
    }

    private func handleRealtimeStateChange(_ stateStr: String) {
        let connectionState: CoordinationConnectionState
        switch stateStr {
        case "connecting": connectionState = .connecting
        case "connected":
            connectionState = .connected
            update { $0.lastError = nil }
        case "reconnecting": connectionState = .reconnecting
        case "disconnected", "interrupted":
            if lock.withLock({ manualDisconnect }) {
                return
            }
            connectionState = .disconnected
        default: return
        }

        update { $0.connectionState = connectionState }
    }

    private func handleRealtimeEnvelope(_ json: String) {
        guard let dict = JSONUtilities.parse(json) else { return }
        guard let type = dict["type"] as? String else { return }

        switch type {
        case "welcome":
            Task { try? await refreshDevices() }
            requestSnapshots()

        case "devices_changed":
            if let devicesData = dict["devices"] as? [[String: Any]] {
                let devices = devicesData.compactMap { CoordinationDevice(json: $0) }
                update {
                    $0.devices = devices
                    $0.lastSyncAt = Date()
                }
            }

        case "snapshot_projection":
            if let deviceId = dict["deviceId"] as? String,
               !deviceId.isEmpty {
                if let snapshot = dict["snapshot"] as? [String: Any],
                   let parsed = CoordinationPlaybackSnapshot(json: snapshot) {
                    let generation = toInt(dict["generation"]) ?? 0
                    let snapshotRevision = toInt(dict["snapshotRevision"]) ?? 0
                    let isOnline = dict["isOnline"] as? Bool ?? false
                    let serverTime = toDouble(dict["serverTime"]) ?? toDouble(dict["lastConfirmedAt"]) ?? 0
                    let lastConfirmedAt = toDouble(dict["lastConfirmedAt"]) ?? 0

                    let deviceSnapshot = CoordinationDeviceSnapshot(
                        deviceId: deviceId,
                        snapshot: parsed,
                        isOnline: isOnline,
                        generation: generation,
                        snapshotRevision: snapshotRevision,
                        serverTime: serverTime,
                        lastConfirmedAt: lastConfirmedAt
                    )
                    update {
                        $0.deviceSnapshots[deviceId] = deviceSnapshot
                    }
                } else {
                    update {
                        $0.deviceSnapshots.removeValue(forKey: deviceId)
                    }
                }
            }

        case "handoff_committed":
            if let snapshot = dict["snapshot"] as? [String: Any],
               let parsed = CoordinationPlaybackSnapshot(json: snapshot) {
                let transactionId = dict["transactionId"] as? String ?? ""
                let newGeneration = toInt(dict["newGeneration"]) ?? 0
                emit(.handoffCommitted(transactionId: transactionId, snapshot: parsed, newGeneration: newGeneration))
            }

        case "handoff_failed":
            let transactionId = dict["transactionId"] as? String
            let code = dict["code"] as? String ?? "unknown"
            emit(.handoffFailed(transactionId: transactionId, code: code))

        case "session_superseded":
            let supersededGeneration = toInt(dict["supersededGeneration"]) ?? 0
            let transferredToDevice = dict["transferredToDevice"] as? String
            emit(.sessionSuperseded(supersededGeneration: supersededGeneration, transferredToDevice: transferredToDevice))

        case "capability_disabled":
            let feature = dict["feature"] as? String ?? ""
            emit(.capabilityDisabled(feature: feature))

        case "error":
            let code = dict["code"] as? String ?? CoordinationErrorCode.internal
            let reason = dict["reason"] as? String
            let error = CoordinationError(code: code, reason: reason)
            if code == CoordinationErrorCode.deviceRevoked {
                handleDeviceRevoked(error)
            } else {
                update { $0.lastError = error }
                emit(.error(error))
            }

        default:
            break
        }
    }

    private func handleCommandAck(messageId: String, resultJson: String) {
        guard let resultDict = JSONUtilities.parse(resultJson) else { return }

        let ack = lock.withLock { () -> PendingAck? in
            pendingAcks.removeValue(forKey: messageId)
        }

        guard let ack else { return }

        ack.timeoutWorkItem.cancel()

        let status = resultDict["status"] as? String
        let code = resultDict["code"] as? String

        if status == "ok" {
            ack.continuation.resume(returning: .ok)
        } else if status == "error" {
            if code == CoordinationErrorCode.staleEpoch && !ack.retried {
                let newGeneration = transport.generation(for: ack.targetDeviceId)

                if let newGeneration {
                    let newMessageId = UUID().uuidString
                    let newTimeoutWorkItem = DispatchWorkItem { [weak self] in
                        let wasRemoved = self?.lock.withLock {
                            self?.pendingAcks.removeValue(forKey: newMessageId)
                        } != nil
                        if wasRemoved {
                            ack.continuation.resume(throwing: CoordinationError(code: CoordinationErrorCode.timeout))
                        }
                    }

                    lock.withLock {
                        var newAck = ack
                        newAck.retried = true
                        newAck.timeoutWorkItem = newTimeoutWorkItem
                        self.pendingAcks[newMessageId] = newAck
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout, execute: newTimeoutWorkItem)

                    onMain { [weak self] in
                        self?.transport.sendCommand(ack.command, targetDeviceId: ack.targetDeviceId, expectedGeneration: newGeneration, messageId: newMessageId)
                    }
                } else {
                    let reason = resultDict["reason"] as? String
                    ack.continuation.resume(returning: .error(code: code ?? "stale_epoch", reason: reason))
                }
            } else {
                let reason = resultDict["reason"] as? String
                ack.continuation.resume(returning: .error(code: code ?? "error", reason: reason))
            }
        } else {
            ack.continuation.resume(returning: .error(code: "error", reason: nil))
        }
    }

    private func handleRemoteCommandExecuted(_ commandDict: [String: Any], sourceDeviceId: String?) {
        if let command = CoordinationRemoteCommand(json: commandDict) {
            emit(.remoteCommandExecuted(command, sourceDeviceId: sourceDeviceId))
        }
    }

    private func handleDeviceRevoked(_ error: CoordinationError) {
        tokenStore.clearTokens()
        onMain { [weak self] in
            self?.transport.disconnect()
            self?.transport.resetSequence()
        }
        lock.withLock {
            reconnectGeneration &+= 1
            self.client = nil
        }
        update {
            $0.deviceId = nil
            $0.accountId = nil
            $0.devices = []
            $0.deviceSnapshots = [:]
            $0.controlledDeviceId = nil
            $0.connectionState = .disconnected
            $0.lastError = error
        }
        emit(.error(error))
    }

    private func toDouble(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func toInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
