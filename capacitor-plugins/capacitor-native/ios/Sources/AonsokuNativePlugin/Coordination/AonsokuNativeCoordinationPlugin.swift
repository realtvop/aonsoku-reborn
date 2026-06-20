import Foundation
import Capacitor

/// Native coordination plugin for iOS — maintains a background WebSocket
/// connection to the coordination server, bridging remote commands and
/// handoff events to the native queue controller (design §8, §9, §10, §11).
///
/// Multi-stack consistency: the plugin receives the same RemoteCommand types
/// as the Web/Electron observer and dispatches them through the native audio
/// plugin's queue engine. The WebView-side CoordinationManager delegates to
/// this plugin when running on capacitor-ios.
@objc(AonsokuNativeCoordination)
public class AonsokuNativeCoordinationPlugin: CAPPlugin, URLSessionWebSocketDelegate {
    /// §13: exponential backoff. Base 1s, doubled per attempt, capped at 30s.
    private static let baseReconnectDelay: TimeInterval = 1.0
    private static let maxReconnectDelay: TimeInterval = 30.0
    private static let maxReconnectAttempts = 10

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts = 0
    private var isConnecting = false
    private var deviceId: String?
    private var capabilities: Int = 0
    private var protocolVersion: Int = 1
    private var heartbeatTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var keychainService = "aonsoku-coordination"

    // MARK: - Token & Config Storage

    @objc func storeTokens(_ call: CAPPluginCall) {
        guard let accessToken = call.getString("accessToken"),
              let refreshToken = call.getString("refreshToken"),
              let deviceId = call.getString("deviceId"),
              let accountId = call.getString("accountId") else {
            call.reject("missing token fields")
            return
        }
        let historyLimit = call.getInt("historyLimit") ?? 100

        KeychainManager.shared.set(accessToken, forKey: "coord_access_token", service: keychainService)
        KeychainManager.shared.set(refreshToken, forKey: "coord_refresh_token", service: keychainService)
        KeychainManager.shared.set(deviceId, forKey: "coord_device_id", service: keychainService)
        KeychainManager.shared.set(accountId, forKey: "coord_account_id", service: keychainService)
        KeychainManager.shared.set(String(historyLimit), forKey: "coord_history_limit", service: keychainService)

        call.resolve()
    }

    @objc func loadTokens(_ call: CAPPluginCall) {
        guard let accessToken = KeychainManager.shared.get("coord_access_token", service: keychainService),
              let refreshToken = KeychainManager.shared.get("coord_refresh_token", service: keychainService),
              let deviceId = KeychainManager.shared.get("coord_device_id", service: keychainService),
              let accountId = KeychainManager.shared.get("coord_account_id", service: keychainService) else {
            call.resolve()
            return
        }
        let historyLimitStr = KeychainManager.shared.get("coord_history_limit", service: keychainService) ?? "100"
        call.resolve([
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "deviceId": deviceId,
            "accountId": accountId,
            "historyLimit": Int(historyLimitStr) ?? 100,
        ])
    }

    @objc func clearTokens(_ call: CAPPluginCall) {
        KeychainManager.shared.delete("coord_access_token", service: keychainService)
        KeychainManager.shared.delete("coord_refresh_token", service: keychainService)
        KeychainManager.shared.delete("coord_device_id", service: keychainService)
        KeychainManager.shared.delete("coord_account_id", service: keychainService)
        KeychainManager.shared.delete("coord_history_limit", service: keychainService)
        call.resolve()
    }

    @objc func storeConfig(_ call: CAPPluginCall) {
        guard let serverUrl = call.getString("serverUrl"),
              let identityUrl = call.getString("identityUrl") else {
            call.reject("missing config fields")
            return
        }
        UserDefaults.standard.set(serverUrl, forKey: "coord_server_url")
        UserDefaults.standard.set(identityUrl, forKey: "coord_identity_url")
        call.resolve()
    }

    @objc func loadConfig(_ call: CAPPluginCall) {
        guard let serverUrl = UserDefaults.standard.string(forKey: "coord_server_url"),
              let identityUrl = UserDefaults.standard.string(forKey: "coord_identity_url") else {
            call.resolve()
            return
        }
        call.resolve(["serverUrl": serverUrl, "identityUrl": identityUrl])
    }

    // MARK: - WebSocket Connection

    @objc func connect(_ call: CAPPluginCall) {
        guard let wsUrl = call.getString("wsUrl"),
              let ticket = call.getString("ticket"),
              let deviceId = call.getString("deviceId") else {
            call.reject("missing connect fields")
            return
        }
        self.deviceId = deviceId
        self.capabilities = call.getInt("capabilities") ?? 0
        self.protocolVersion = call.getInt("protocolVersion") ?? 1

        let urlWithTicket = buildTicketUrl(wsUrl, ticket: ticket)
        guard let url = URL(string: urlWithTicket) else {
            call.reject("invalid URL")
            return
        }

        disconnectInternal()

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let task = self.session?.webSocketTask(with: url)
        self.webSocketTask = task
        task?.resume()

        self.isConnecting = true
        self.notifyState("connecting")

        call.resolve()
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        disconnectInternal()
        call.resolve()
    }

    @objc func getState(_ call: CAPPluginCall) {
        let state: String
        if self.webSocketTask == nil {
            state = "disconnected"
        } else if self.isConnecting {
            state = "connecting"
        } else {
            state = "connected"
        }
        call.resolve(["state": state, "deviceId": self.deviceId ?? NSNull()])
    }

    @objc func publishSnapshot(_ call: CAPPluginCall) {
        guard let snapshotJson = call.getString("snapshotJson") else {
            call.reject("missing snapshotJson")
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "snapshot",
            "sessionId": call.getString("sessionId") ?? "",
            "generation": call.getInt("generation") ?? 0,
            "snapshotRevision": call.getInt("snapshotRevision") ?? 0,
            "snapshot": JSONUtilities.parse(snapshotJson) ?? [:],
        ]
        sendEnvelope(env)
        call.resolve()
    }

    @objc func sendCommand(_ call: CAPPluginCall) {
        guard let commandJson = call.getString("commandJson"),
              let targetDeviceId = call.getString("targetDeviceId") else {
            call.reject("missing command fields")
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "command",
            "targetDeviceId": targetDeviceId,
            "expectedGeneration": call.getInt("expectedGeneration") ?? 0,
            "command": JSONUtilities.parse(commandJson) ?? [:],
        ]
        sendEnvelope(env)
        call.resolve()
    }

    @objc func requestHandoffCandidate(_ call: CAPPluginCall) {
        guard let sourceDeviceId = call.getString("sourceDeviceId") else {
            call.reject("missing sourceDeviceId")
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "handoff_candidate_request",
            "sourceDeviceId": sourceDeviceId,
            "expectedGeneration": call.getInt("expectedGeneration") ?? 0,
            "expectedSnapshotRevision": call.getInt("expectedSnapshotRevision") ?? 0,
        ]
        sendEnvelope(env)
        call.resolve()
    }

    @objc func sendTargetReady(_ call: CAPPluginCall) {
        guard let transactionId = call.getString("transactionId") else {
            call.reject("missing transactionId")
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "target_ready",
            "transactionId": transactionId,
            "generation": call.getInt("generation") ?? 0,
            "snapshotRevision": call.getInt("snapshotRevision") ?? 0,
        ]
        sendEnvelope(env)
        call.resolve()
    }

    @objc func sendRelinquishAck(_ call: CAPPluginCall) {
        guard let transactionId = call.getString("transactionId"),
              let snapshotJson = call.getString("snapshotJson") else {
            call.reject("missing relinquish fields")
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "relinquish_ack",
            "transactionId": transactionId,
            "snapshot": JSONUtilities.parse(snapshotJson) ?? [:],
        ]
        sendEnvelope(env)
        call.resolve()
    }

    // MARK: - WebSocket Delegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenProtocolWithProtocol protocol: String?) {
        self.isConnecting = false
        self.reconnectAttempts = 0
        self.startHeartbeat()
        self.notifyState("connected")
        self.receiveMessage()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.isConnecting = false
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
        self.notifyState("disconnected")
        self.scheduleReconnect()
    }

    // MARK: - Private Helpers

    private func disconnectInternal() {
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
        self.reconnectWorkItem?.cancel()
        self.reconnectWorkItem = nil
        self.reconnectAttempts = 0
        self.webSocketTask?.cancel()
        self.webSocketTask = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.isConnecting = false
    }

    private func startHeartbeat() {
        self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let env: [String: Any] = [
                "version": self.protocolVersion,
                "messageId": UUID().uuidString,
                "type": "heartbeat",
            ]
            self.sendEnvelope(env)
        }
    }

    private func receiveMessage() {
        self.webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    if let json = String(data: data, encoding: .utf8) {
                        self.dispatchEnvelope(json)
                    }
                case .string(let str):
                    self.dispatchEnvelope(str)
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure:
                self.isConnecting = false
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
                self.notifyState("error")
                self.scheduleReconnect()
            }
        }
    }

    private func dispatchEnvelope(_ json: String) {
        DispatchQueue.main.async {
            self.notifyListeners("coordinationEvent", data: ["envelopeJson": json])
        }
    }

    private func sendEnvelope(_ env: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: env),
              let string = String(data: data, encoding: .utf8) else { return }
        self.webSocketTask?.send(.string(string)) { _ in }
    }

    private func scheduleReconnect() {
        self.reconnectAttempts += 1
        // §13: exponential backoff with a cap. Tickets expire in 30s so the
        // native layer only emits the request; the WebView performs the
        // actual reconnect after refreshing the ticket (§6.3).
        let attempt = min(self.reconnectAttempts, Self.maxReconnectAttempts)
        let delay = min(
            Self.baseReconnectDelay * pow(2.0, Double(attempt - 1)),
            Self.maxReconnectDelay,
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.notifyReconnectNeeded(attempt: attempt)
        }
        self.reconnectWorkItem = workItem
        self.notifyState("reconnecting")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func notifyReconnectNeeded(attempt: Int) {
        DispatchQueue.main.async {
            self.notifyListeners(
                "coordinationReconnectNeeded",
                data: ["attempt": attempt],
            )
        }
    }

    private func notifyState(_ state: String) {
        DispatchQueue.main.async {
            self.notifyListeners("coordinationStateChange", data: [
                "state": state,
                "deviceId": self.deviceId ?? NSNull(),
            ])
        }
    }
}

/// Simple JSON string → dictionary parser.
enum JSONUtilities {
    static func parse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Append the one-time WebSocket ticket as a URL-encoded query parameter so
/// tickets containing &/=/?/# do not break the URL.
enum CoordinationURL {
    static func buildTicketUrl(_ wsUrl: String, ticket: String) -> String {
        let separator = wsUrl.contains("?") ? "&" : "?"
        let encoded = ticket.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed,
        ) ?? ticket
        return wsUrl + separator + "ticket=" + encoded
    }
}