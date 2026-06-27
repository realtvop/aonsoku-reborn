import Foundation
import AVFoundation
import Capacitor
import UIKit

private struct PendingNativeCommand {
    let targetDeviceId: String
    let command: [String: Any]
    let attemptedStaleRetry: Bool
}

/// Native coordination plugin for iOS — maintains a background WebSocket
/// connection to the coordination server, bridging remote commands and
/// handoff events to the native queue controller (design §8, §9, §10, §11).
///
/// Background lifecycle (design §2.1.8, §5.2): the coordination URLSession uses
/// `URLSessionConfiguration.background` with a unique identifier
/// (`com.aonsoku.coordination`) and
/// `shouldUseExtendedBackgroundIdleMode = true` so iOS keeps the WebSocket
/// eligible for execution while the app is backgrounded, as long as the audio
/// session is active. The plugin mirrors the AVAudioSession interruption /
/// route-change observer pattern used by `AonsokuNativeAudioPlugin`: when the
/// audio session is active the coordination session is kept eligible for
/// background execution; when the audio session is interrupted (e.g. another
/// app takes audio, battery saver, or background audio is disabled) the plugin
/// degrades gracefully — stops the heartbeat, emits `disconnected` via
/// `coordinationStateChange`, and resumes on the next foreground entry or
/// `urlSessionDidFinishEvents(forBackgroundURLSession:)` relaunch.
///
/// Multi-stack consistency: the plugin receives the same RemoteCommand types
/// as the Web/Electron observer and dispatches them through the native audio
/// plugin's queue engine. The WebView-side CoordinationManager delegates to
/// this plugin when running on capacitor-ios.
@objc(AonsokuNativeCoordination)
public class AonsokuNativeCoordinationPlugin: CAPPlugin, URLSessionWebSocketDelegate, URLSessionDelegate {
    /// §13: exponential backoff. Base 1s, doubled per attempt, capped at 30s.
    private static let baseReconnectDelay: TimeInterval = 1.0
    private static let maxReconnectDelay: TimeInterval = 30.0
    private static let maxReconnectAttempts = 10
    /// Background URLSession identifier used to relaunch the app and to
    /// re-enqueue events when iOS finishes background work (design §2.1.8).
    private static let backgroundSessionIdentifier = "com.aonsoku.coordination"
    private static weak var activeInstance: AonsokuNativeCoordinationPlugin?

    internal static func sendCommandFromActive(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: [String: Any]
    ) -> Bool {
        guard let instance = activeInstance else {
            return false
        }
        return instance.sendCommandFromNative(
            targetDeviceId: targetDeviceId,
            expectedGeneration: expectedGeneration,
            command: command
        )
    }

    internal static func publishSnapshotFromActiveAudioState() -> Bool {
        activeInstance?.publishNativePlaybackSnapshot() ?? false
    }

    internal static func buildCommandAckEnvelope(
        protocolVersion: Int,
        messageId: String,
        result: [String: Any] = ["status": "ok"]
    ) -> [String: Any] {
        [
            "version": protocolVersion,
            "messageId": messageId,
            "type": "command_ack",
            "result": result,
        ]
    }

    internal static func buildRelinquishAckEnvelope(
        protocolVersion: Int,
        transactionId: String,
        snapshot: [String: Any]
    ) -> [String: Any] {
        [
            "version": protocolVersion,
            "messageId": UUID().uuidString,
            "type": "relinquish_ack",
            "transactionId": transactionId,
            "snapshot": snapshot,
        ]
    }

    internal static func buildHandoffFailedEnvelope(
        protocolVersion: Int,
        transactionId: String,
        code: String
    ) -> [String: Any] {
        [
            "version": protocolVersion,
            "messageId": UUID().uuidString,
            "type": "handoff_failed",
            "transactionId": transactionId,
            "code": code,
        ]
    }

    internal static func buildTargetReadyEnvelope(
        protocolVersion: Int,
        transactionId: String,
        generation: Int,
        snapshotRevision: Int,
        sourceDeviceId: String,
        sessionId: String
    ) -> [String: Any] {
        [
            "version": protocolVersion,
            "messageId": UUID().uuidString,
            "type": "target_ready",
            "transactionId": transactionId,
            "generation": generation,
            "snapshotRevision": snapshotRevision,
            "sourceDeviceId": sourceDeviceId,
            "sessionId": sessionId,
        ]
    }

    internal static func buildPlaybackSnapshot(
        sessionId: String,
        audioState: [String: Any],
        sampledAtSeconds: Double,
        volume: Double? = nil
    ) -> [String: Any]? {
        guard let songId = audioState["currentSongId"] as? String, !songId.isEmpty else {
            return nil
        }

        let contextQueue = audioState["contextQueue"] as? [String: Any] ?? [:]
        return [
            "sessionId": sessionId,
            "logicalPlaybackSessionId": sessionId,
            "mediaKind": "song",
            "songId": songId,
            "progressSeconds": max(number(audioState["currentTime"]) ?? 0, 0),
            "durationSeconds": max(number(audioState["duration"]) ?? 0, 0),
            "isPlaying": audioState["isPlaying"] as? Bool ?? false,
            "sampledAt": sampledAtSeconds,
            "contextQueue": songIds(contextQueue["songs"]),
            "contextIndex": max(int(contextQueue["currentIndex"]) ?? 0, 0),
            "sourceId": encodeSourceId(contextQueue["sourceId"]),
            "sourceName": stringOrNull(contextQueue["sourceName"]),
            "userQueue": songIds(audioState["userQueue"]),
            "inUserQueue": audioState["isInUserQueue"] as? Bool ?? false,
            "restorePrevious": songIds(audioState["playedUserQueueHistory"]),
            "shuffle": audioState["isShuffleActive"] as? Bool ?? false,
            "repeat": audioState["loopState"] as? String ?? "off",
            "volume": volume ?? NSNull(),
            "accumulatedPlaySeconds": 0.0,
            "historyWritten": false,
            "nowPlayingSent": false,
            "scrobbleSent": false,
        ]
    }

    private static func songIds(_ value: Any?) -> [String] {
        let songs = value as? [[String: Any]] ?? []
        return songs.compactMap { song in
            let id = song["id"] as? String
            return id?.isEmpty == false ? id : nil
        }
    }

    private static func encodeSourceId(_ value: Any?) -> Any {
        guard let sourceId = value as? [String: Any],
              let type = sourceId["type"] as? String,
              let id = sourceId["id"] as? String,
              !type.isEmpty,
              !id.isEmpty else {
            return NSNull()
        }
        return "\(type):\(id)"
    }

    private static func stringOrNull(_ value: Any?) -> Any {
        guard let value = value as? String, !value.isEmpty else {
            return NSNull()
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts = 0
    private var isConnecting = false
    /// True after an explicit `disconnect()`. Prevents the auto-reconnect path
    /// from firing for a user-initiated close.
    private var manualDisconnect = false
    private var deviceId: String?
    private var capabilities: Int = 0
    private var protocolVersion: Int = 1
    private var currentTicket: String?
    private var connectLastSeq: Int = 0
    private var nativeSessionId = UUID().uuidString
    private var nativeGeneration = 1
    private var nativeSnapshotRevision = 0
    private var deviceGenerations: [String: Int] = [:]
    private var deviceSnapshotRevisions: [String: Int] = [:]
    private var activeRemoteControlTargetDeviceId: String?
    private var pendingNativeHandoffSourceDeviceId: String?
    private var pendingNativeHandoffRetryWaitingForSnapshot = false
    private var pendingNativeHandoffRetryCount = 0
    private var pendingNativeCommands: [String: PendingNativeCommand] = [:]
    private var heartbeatTimer: Timer?
    private var snapshotHeartbeatTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var keychainService = "aonsoku-coordination"
    /// §9.1 dedup cache for incoming envelopes.
    private var dedupCache = CoordinationDedup(max: 200)
    /// §9.2 sequence tracker — highest server seq processed.
    private var seqTracker = CoordinationSeqTracker()

    /// Saved by the app delegate when iOS relaunches the app for a background
    /// URLSession completion. Invoked from
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` so a relaunch in
    /// the background reconnects cleanly (design §2.1.8).
    private var backgroundCompletionHandler: (() -> Void)?

    /// Audio-session observers mirroring AonsokuNativeAudioPlugin's pattern.
    /// When the audio session is active the coordination URLSession is kept
    /// eligible for background execution; when interrupted, the plugin
    /// degrades gracefully.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var didEnterBackgroundObserver: NSObjectProtocol?
    private var willEnterForegroundObserver: NSObjectProtocol?

    // MARK: - Plugin Lifecycle

    public override func load() {
        super.load()
        Self.activeInstance = self
        registerAudioSessionObservers()
    }

    deinit {
        if Self.activeInstance === self {
            Self.activeInstance = nil
        }
        removeAudioSessionObservers()
    }

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

        KeychainManager.set(accessToken, forKey: "coord_access_token", service: keychainService)
        KeychainManager.set(refreshToken, forKey: "coord_refresh_token", service: keychainService)
        KeychainManager.set(deviceId, forKey: "coord_device_id", service: keychainService)
        KeychainManager.set(accountId, forKey: "coord_account_id", service: keychainService)
        KeychainManager.set(String(historyLimit), forKey: "coord_history_limit", service: keychainService)

        call.resolve()
    }

    @objc func loadTokens(_ call: CAPPluginCall) {
        guard let accessToken = KeychainManager.get("coord_access_token", service: keychainService),
              let refreshToken = KeychainManager.get("coord_refresh_token", service: keychainService),
              let deviceId = KeychainManager.get("coord_device_id", service: keychainService),
              let accountId = KeychainManager.get("coord_account_id", service: keychainService) else {
            call.resolve()
            return
        }
        let historyLimitStr = KeychainManager.get("coord_history_limit", service: keychainService) ?? "100"
        call.resolve([
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "deviceId": deviceId,
            "accountId": accountId,
            "historyLimit": Int(historyLimitStr) ?? 100,
        ])
    }

    @objc func clearTokens(_ call: CAPPluginCall) {
        KeychainManager.delete("coord_access_token", service: keychainService)
        KeychainManager.delete("coord_refresh_token", service: keychainService)
        KeychainManager.delete("coord_device_id", service: keychainService)
        KeychainManager.delete("coord_account_id", service: keychainService)
        KeychainManager.delete("coord_history_limit", service: keychainService)
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

    @objc func request(_ call: CAPPluginCall) {
        guard let rawUrl = call.getString("url"),
              let url = URL(string: rawUrl) else {
            call.reject("missing or invalid url")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = call.getString("method") ?? "GET"
        if let headers = call.getObject("headers") {
            for (key, value) in headers {
                request.setValue("\(value)", forHTTPHeaderField: key)
            }
        }
        if let body = call.getString("body") {
            request.httpBody = body.data(using: .utf8)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                call.reject("native coordination request failed: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                call.reject("native coordination request failed: no HTTP response")
                return
            }
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            call.resolve([
                "status": httpResponse.statusCode,
                "statusText": HTTPURLResponse.localizedString(
                    forStatusCode: httpResponse.statusCode
                ),
                "body": body,
            ])
        }.resume()
    }

    // MARK: - WebSocket Connection

    @objc func connect(_ call: CAPPluginCall) {
        guard let wsUrl = call.getString("wsUrl"),
              let ticket = call.getString("ticket"),
              let deviceId = call.getString("deviceId") else {
            call.reject("missing connect fields")
            return
        }
        let capabilities = call.getInt("capabilities") ?? 0
        let protocolVersion = call.getInt("protocolVersion") ?? 1
        // §9.2: the client submits the highest seq it has processed so the
        // server can skip already-delivered messages. When the caller omits
        // lastSeq (first-ever connect), default to 0.
        let lastSeqValue = call.getInt("lastSeq") ?? 0

        // Lifecycle correctness (§2.1.8): if the socket is already open, do
        // not create a second one when the app returns to the foreground or
        // iOS relaunches the app for the background session. Reuse the
        // existing connection.
        if let task = self.webSocketTask, !self.isConnecting, task.state == .running {
            call.resolve()
            return
        }

        let urlWithTicket = CoordinationURL.buildTicketUrl(wsUrl, ticket: ticket)
        guard let url = URL(string: urlWithTicket) else {
            call.reject("invalid URL")
            return
        }

        self.manualDisconnect = false
        self.disconnectInternal()
        self.deviceId = deviceId
        self.currentTicket = ticket
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
        self.connectLastSeq = lastSeqValue
        self.seqTracker = CoordinationSeqTracker()
        self.seqTracker.observe(Int64(lastSeqValue))
        // The dedup cache is per-connection; clear it so a reconnect does
        // not falsely skip messages from the new connection.
        self.dedupCache.clear()

        // §2.1.8: use a background URLSession so iOS keeps the WebSocket
        // eligible for execution while the app is backgrounded, as long as
        // the audio session is active. Extended idle mode keeps the session
        // from being torn down during short idle periods.
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.shouldUseExtendedBackgroundIdleMode = true
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let task = self.session?.webSocketTask(with: url)
        self.webSocketTask = task
        task?.resume()

        self.isConnecting = true
        self.notifyState("connecting")

        call.resolve()
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        self.manualDisconnect = true
        self.disconnectInternal()
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
        // §9.1: the caller may supply a messageId to match the command to a
        // pending-ack promise. Fall back to a generated UUID.
        activeRemoteControlTargetDeviceId = targetDeviceId
        let suppliedMessageId = call.getString("messageId")
        let messageId = suppliedMessageId ?? UUID().uuidString
        let command = JSONUtilities.parse(commandJson) ?? [:]
        if suppliedMessageId == nil {
            pendingNativeCommands[messageId] = PendingNativeCommand(
                targetDeviceId: targetDeviceId,
                command: command,
                attemptedStaleRetry: false
            )
        }
        sendCommandEnvelope(
            messageId: messageId,
            targetDeviceId: targetDeviceId,
            expectedGeneration: call.getInt("expectedGeneration") ?? 0,
            command: command
        )
        call.resolve()
    }

    @objc func sendActiveControlCommand(_ call: CAPPluginCall) {
        guard let commandJson = call.getString("commandJson") else {
            call.reject("missing commandJson")
            return
        }
        guard let targetDeviceId = activeRemoteControlTargetDeviceId else {
            call.reject("missing active target")
            return
        }
        let command = JSONUtilities.parse(commandJson) ?? [:]
        guard Self.sendCommandFromActive(
            targetDeviceId: targetDeviceId,
            expectedGeneration: deviceGenerations[targetDeviceId],
            command: command
        ) else {
            call.reject("native coordination is not connected")
            return
        }
        call.resolve()
    }

    @objc func sendControlSessionBegin(_ call: CAPPluginCall) {
        guard let targetDeviceId = call.getString("targetDeviceId") else {
            call.reject("missing targetDeviceId")
            return
        }
        activeRemoteControlTargetDeviceId = targetDeviceId
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "control_session_begin",
            "targetDeviceId": targetDeviceId,
        ]
        sendEnvelope(env)
        call.resolve()
    }

    @objc func sendControlSessionEnd(_ call: CAPPluginCall) {
        activeRemoteControlTargetDeviceId = nil
        AonsokuNativeAudioPlugin.clearRemotePlaybackProjectionFromActive()
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "control_session_end",
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

    @objc func requestHandoffCandidateFromCache(_ call: CAPPluginCall) {
        guard let sourceDeviceId = call.getString("sourceDeviceId") else {
            call.reject("missing sourceDeviceId")
            return
        }
        guard sendHandoffCandidateRequestFromCache(sourceDeviceId: sourceDeviceId) else {
            call.reject("missing cached handoff snapshot")
            return
        }
        pendingNativeHandoffSourceDeviceId = sourceDeviceId
        pendingNativeHandoffRetryWaitingForSnapshot = false
        pendingNativeHandoffRetryCount = 0
        call.resolve()
    }

    @objc func sendTargetReady(_ call: CAPPluginCall) {
        guard let transactionId = call.getString("transactionId"),
              let sourceDeviceId = call.getString("sourceDeviceId"),
              let sessionId = call.getString("sessionId") else {
            call.reject("missing target_ready fields")
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "target_ready",
            "transactionId": transactionId,
            "generation": call.getInt("generation") ?? 0,
            "snapshotRevision": call.getInt("snapshotRevision") ?? 0,
            "sourceDeviceId": sourceDeviceId,
            "sessionId": sessionId,
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

    @objc func requestSnapshots(_ call: CAPPluginCall) {
        requestSnapshots()
        call.resolve()
    }

    private func requestSnapshots() {
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "request_snapshots",
        ]
        sendEnvelope(env)
    }

    private func sendHandoffCandidateRequestFromCache(sourceDeviceId: String) -> Bool {
        guard let generation = deviceGenerations[sourceDeviceId],
              let snapshotRevision = deviceSnapshotRevisions[sourceDeviceId] else {
            return false
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "handoff_candidate_request",
            "sourceDeviceId": sourceDeviceId,
            "expectedGeneration": generation,
            "expectedSnapshotRevision": snapshotRevision,
        ]
        sendEnvelope(env)
        return true
    }

    // MARK: - WebSocket Delegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenProtocolWithProtocol protocol: String?) {
        self.isConnecting = false
        self.reconnectAttempts = 0
        self.sendHello()
        self.startHeartbeat()
        self.startSnapshotHeartbeat()
        self.notifyState("connected")
        self.receiveMessage()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.isConnecting = false
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
        self.stopSnapshotHeartbeat()
        self.notifyState("disconnected")
        // §2.1.8 / §6.3: only schedule a reconnect for OS-initiated closes,
        // not for an explicit user disconnect.
        if !self.manualDisconnect { self.scheduleReconnect() }
    }

    // MARK: - Background URLSession completion (§2.1.8)

    /// Called by iOS when all enqueued background URLSession work is done and
    /// the app may have been relaunched in the background. If the app was
    /// relaunched we must invoke the completion handler the app delegate
    /// saved, otherwise iOS will keep the app alive needlessly. If the
    /// coordination socket dropped in the background we surface it via
    /// `coordinationStateChange` so the WebView reconnects on the next
    /// foreground entry.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let handler = self.backgroundCompletionHandler {
                self.backgroundCompletionHandler = nil
                handler()
            }
            // If the socket is gone after the background session finished,
            // emit a state change so the WebView re-arms a reconnect.
            if self.webSocketTask == nil || self.webSocketTask?.state != .running {
                self.notifyState("disconnected")
                if !self.manualDisconnect { self.scheduleReconnect() }
            }
        }
    }

    /// Called by the app delegate to hand off the background completion
    /// handler iOS gave it when relaunching the app for the background
    /// URLSession. Stored until `urlSessionDidFinishEvents` fires.
    @objc public func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        self.backgroundCompletionHandler = handler
    }

    // MARK: - Audio Session Observers (§2.1.8)

    /// Mirrors the observer pattern in AonsokuNativeAudioPlugin. When the
    /// audio session is active the coordination URLSession is kept eligible
    /// for background execution; when interrupted the plugin degrades
    /// gracefully (stops heartbeat, emits `disconnected`, resumes on the next
    /// foreground entry). Per AGENTS.md, interruptions are surfaced via
    /// `coordinationStateChange` and never silently ignored.
    private func registerAudioSessionObservers() {
        let center = NotificationCenter.default

        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
        }

        if routeChangeObserver == nil {
            routeChangeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                // Route changes do not require coordination action; we only
                // observe to keep the session eligible. No-op here.
            }
        }

        if didEnterBackgroundObserver == nil {
            didEnterBackgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // §2.1.8: the background URLSession keeps the socket alive
                // while the audio session is active. We do NOT close here.
                // Graceful degradation is driven by the audio-session
                // interruption observer and the OS background restrictions.
            }
        }

        if willEnterForegroundObserver == nil {
            willEnterForegroundObserver = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // §2.1.8: on foreground re-entry, if the socket dropped in the
                // background, emit a state change so the WebView reconnects.
                // Do not create a second socket if still connected.
                guard let self = self else { return }
                if self.webSocketTask == nil || self.webSocketTask?.state != .running {
                    if !self.manualDisconnect {
                        self.notifyState("disconnected")
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    private func removeAudioSessionObservers() {
        let center = NotificationCenter.default
        for observer in [interruptionObserver, routeChangeObserver, didEnterBackgroundObserver, willEnterForegroundObserver] {
            if let observer { center.removeObserver(observer) }
        }
        interruptionObserver = nil
        routeChangeObserver = nil
        didEnterBackgroundObserver = nil
        willEnterForegroundObserver = nil
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            // §2.1.8 graceful degradation: the audio session is interrupted
            // (another app took audio, battery saver, or background audio was
            // disabled). Stop the heartbeat and surface the state change so
            // other devices see us go offline cleanly. We do not close the
            // socket here — iOS will reap the background URLSession if it
            // cannot continue; the foreground observer re-arms a reconnect.
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
            self.stopSnapshotHeartbeat()
            self.notifyState("interrupted")
        case .ended:
            // The audio session resumed. If we still have a socket, restart
            // the heartbeat; otherwise emit a reconnect request.
            if self.webSocketTask?.state == .running {
                self.startHeartbeat()
                self.startSnapshotHeartbeat()
                self.notifyState("connected")
            } else if !self.manualDisconnect {
                self.notifyState("disconnected")
                self.scheduleReconnect()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Private Helpers

    private func disconnectInternal() {
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
        self.stopSnapshotHeartbeat()
        self.reconnectWorkItem?.cancel()
        self.reconnectWorkItem = nil
        self.reconnectAttempts = 0
        self.webSocketTask?.cancel()
        self.webSocketTask = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.isConnecting = false
        self.currentTicket = nil
        // §9.1/§9.2: clear the dedup cache and reset the seq tracker so a
        // reconnect starts clean. The next `connect()` call supplies the
        // lastSeq option again.
        self.dedupCache.clear()
        self.seqTracker.reset()
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

    private func startSnapshotHeartbeat() {
        self.stopSnapshotHeartbeat()
        self.snapshotHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.publishNativePlaybackSnapshot(onlyWhenPlaying: true)
        }
    }

    private func stopSnapshotHeartbeat() {
        self.snapshotHeartbeatTimer?.invalidate()
        self.snapshotHeartbeatTimer = nil
    }

    private func sendHello() {
        guard let deviceId = self.deviceId,
              let ticket = self.currentTicket else {
            return
        }
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "hello",
            "protocolVersion": self.protocolVersion,
            "capabilities": self.capabilities,
            "deviceId": deviceId,
            "ticket": ticket,
            "lastSeq": self.connectLastSeq,
        ]
        self.sendEnvelope(env)
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
                self.stopSnapshotHeartbeat()
                self.notifyState("error")
                if !self.manualDisconnect { self.scheduleReconnect() }
            }
        }
    }

    private func dispatchEnvelope(_ json: String) {
        // Parse once to extract routing metadata, then forward the raw JSON
        // to the WebView so it can re-parse into the full Envelope type.
        if let dict = JSONUtilities.parse(json) {
            // §9.2: track the incoming seq on every envelope.
            if let seq = dict["seq"] as? Int64 {
                self.seqTracker.observe(seq)
            } else if let seq = dict["seq"] as? Int {
                self.seqTracker.observe(Int64(seq))
            } else if let seq = dict["seq"] as? Double {
                self.seqTracker.observe(Int64(seq))
            }
            // §9.1: dedup command/snapshot_projection envelopes by messageId.
            if let type = dict["type"] as? String,
               type == "snapshot_projection",
               let deviceId = dict["deviceId"] as? String,
               !deviceId.isEmpty,
               let generation = dict["generation"] as? Int,
               generation > 0 {
                self.deviceGenerations[deviceId] = generation
                if let snapshotRevision = dict["snapshotRevision"] as? Int,
                   snapshotRevision > 0 {
                    self.deviceSnapshotRevisions[deviceId] = snapshotRevision
                }
                if pendingNativeHandoffRetryWaitingForSnapshot,
                   deviceId == pendingNativeHandoffSourceDeviceId,
                   sendHandoffCandidateRequestFromCache(sourceDeviceId: deviceId) {
                    pendingNativeHandoffRetryWaitingForSnapshot = false
                }
                if deviceId == self.activeRemoteControlTargetDeviceId {
                    if dict["isOnline"] as? Bool == false {
                        AonsokuNativeAudioPlugin.clearRemotePlaybackProjectionFromActive()
                    } else if let snapshot = dict["snapshot"] as? [String: Any] {
                        AonsokuNativeAudioPlugin.updateRemotePlaybackProjectionFromActive(
                            snapshot: snapshot,
                            targetDeviceId: deviceId,
                            expectedGeneration: generation
                        )
                    }
                }
            }
            if let type = dict["type"] as? String,
               type == "command" || type == "snapshot_projection",
               let id = dict["messageId"] as? String {
                if self.dedupCache.has(id) {
                    // Duplicate — skip re-dispatching (debug-level only).
                    return
                }
                self.dedupCache.mark(id)
            }
            // §9.1: native-origin commands consume their ack entirely in the
            // native layer. Only JS-origin commands are bridged back so the
            // WebView facade can resolve its pending sendCommand() promise.
            if let type = dict["type"] as? String, type == "command_ack" {
                if !self.handleNativeCommandAck(dict) {
                    let messageId = dict["messageId"] as? String ?? ""
                    let result: String
                    if let r = dict["result"] {
                        if let data = try? JSONSerialization.data(withJSONObject: r),
                           let str = String(data: data, encoding: .utf8) {
                            result = str
                        } else {
                            result = "{}"
                        }
                    } else {
                        result = "{}"
                    }
                    DispatchQueue.main.async {
                        self.notifyListeners(
                            "coordinationAck",
                            data: [
                                "messageId": messageId,
                                "resultJson": result,
                            ]
                        )
                    }
                }
            }
            if let type = dict["type"] as? String,
               type == "command",
               let command = dict["command"] as? [String: Any],
               AonsokuNativeAudioPlugin.executeRemoteControlCommandFromActive(command) {
                if let messageId = dict["messageId"] as? String {
                    self.sendEnvelope(Self.buildCommandAckEnvelope(
                        protocolVersion: self.protocolVersion,
                        messageId: messageId
                    ))
                }
                return
            }
            if let type = dict["type"] as? String,
               type == "error",
               dict["code"] as? String == "source_changed",
               pendingNativeHandoffSourceDeviceId != nil,
               pendingNativeHandoffRetryCount < 2 {
                pendingNativeHandoffRetryCount += 1
                pendingNativeHandoffRetryWaitingForSnapshot = true
                requestSnapshots()
                return
            }
            if let type = dict["type"] as? String,
               type == "prepare_relinquish",
               let transactionId = dict["transactionId"] as? String,
               !transactionId.isEmpty {
                if let audioState = AonsokuNativeAudioPlugin.pauseAndGetFullStateFromActive(),
                   let snapshot = Self.buildPlaybackSnapshot(
                       sessionId: nativeSessionId,
                       audioState: audioState,
                       sampledAtSeconds: Date().timeIntervalSince1970
                   ) {
                    self.sendEnvelope(Self.buildRelinquishAckEnvelope(
                        protocolVersion: self.protocolVersion,
                        transactionId: transactionId,
                        snapshot: snapshot
                    ))
                } else {
                    self.sendEnvelope(Self.buildHandoffFailedEnvelope(
                        protocolVersion: self.protocolVersion,
                        transactionId: transactionId,
                        code: "source_pause_timeout"
                    ))
                }
                return
            }
            if let type = dict["type"] as? String,
               type == "handoff_candidate" {
                let snapshot = dict["snapshot"] as? [String: Any]
                let transactionId = dict["transactionId"] as? String ?? ""
                let sourceDeviceId = dict["sourceDeviceId"] as? String ?? ""
                let sessionId = dict["sessionId"] as? String ?? ""
                let canPrepare = snapshot != nil &&
                    !transactionId.isEmpty &&
                    !sourceDeviceId.isEmpty &&
                    !sessionId.isEmpty
                let accepted = canPrepare && AonsokuNativeAudioPlugin.prepareHandoffPlaybackFromActive(
                    snapshot: snapshot ?? [:],
                    autoplay: false,
                    completion: { prepared in
                        if prepared {
                            self.sendEnvelope(Self.buildTargetReadyEnvelope(
                                protocolVersion: self.protocolVersion,
                                transactionId: transactionId,
                                generation: dict["generation"] as? Int ?? 0,
                                snapshotRevision: dict["snapshotRevision"] as? Int ?? 0,
                                sourceDeviceId: sourceDeviceId,
                                sessionId: sessionId
                            ))
                        } else {
                            self.sendEnvelope(Self.buildHandoffFailedEnvelope(
                                protocolVersion: self.protocolVersion,
                                transactionId: transactionId,
                                code: "unsupported_media"
                            ))
                        }
                    }
                )
                if !accepted && !transactionId.isEmpty {
                    self.sendEnvelope(Self.buildHandoffFailedEnvelope(
                        protocolVersion: self.protocolVersion,
                        transactionId: transactionId,
                        code: "unsupported_media"
                    ))
                }
                return
            }
            if let type = dict["type"] as? String,
               type == "handoff_committed",
               let snapshot = dict["snapshot"] as? [String: Any],
               AonsokuNativeAudioPlugin.prepareHandoffPlaybackFromActive(
                   snapshot: snapshot,
                   autoplay: true,
                   completion: { _ in }
               ) {
                pendingNativeHandoffSourceDeviceId = nil
                pendingNativeHandoffRetryWaitingForSnapshot = false
                pendingNativeHandoffRetryCount = 0
                return
            }
            if let type = dict["type"] as? String, type == "handoff_failed" {
                pendingNativeHandoffSourceDeviceId = nil
                pendingNativeHandoffRetryWaitingForSnapshot = false
                pendingNativeHandoffRetryCount = 0
            }
            if let type = dict["type"] as? String,
               type == "session_superseded" {
                nativeSessionId = UUID().uuidString
                nativeGeneration = 1
                nativeSnapshotRevision = 0
                _ = AonsokuNativeAudioPlugin.executeRemoteControlCommandFromActive(["type": "pause"])
                return
            }
        }
        DispatchQueue.main.async {
            self.notifyListeners("coordinationEvent", data: ["envelopeJson": json])
        }
    }

    private func sendEnvelope(_ env: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: env),
              let string = String(data: data, encoding: .utf8) else { return }
        self.webSocketTask?.send(.string(string)) { _ in }
    }

    private func publishNativePlaybackSnapshot(onlyWhenPlaying: Bool = false) -> Bool {
        guard self.webSocketTask != nil,
              let audioState = AonsokuNativeAudioPlugin.getFullStateFromActive(),
              let snapshot = Self.buildPlaybackSnapshot(
                sessionId: nativeSessionId,
                audioState: audioState,
                sampledAtSeconds: Date().timeIntervalSince1970
              ) else {
            return false
        }

        if onlyWhenPlaying && (audioState["isPlaying"] as? Bool != true) {
            return false
        }

        nativeSnapshotRevision += 1
        sendEnvelope([
            "version": protocolVersion,
            "messageId": UUID().uuidString,
            "type": "snapshot",
            "sessionId": nativeSessionId,
            "generation": nativeGeneration,
            "snapshotRevision": nativeSnapshotRevision,
            "snapshot": snapshot,
        ])
        return true
    }

    private func sendCommandFromNative(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: [String: Any]
    ) -> Bool {
        guard self.webSocketTask != nil else {
            return false
        }
        guard let generation = expectedGeneration ?? deviceGenerations[targetDeviceId] else {
            return false
        }

        let messageId = UUID().uuidString
        pendingNativeCommands[messageId] = PendingNativeCommand(
            targetDeviceId: targetDeviceId,
            command: command,
            attemptedStaleRetry: false
        )
        sendCommandEnvelope(
            messageId: messageId,
            targetDeviceId: targetDeviceId,
            expectedGeneration: generation,
            command: command
        )
        return true
    }

    private func sendCommandEnvelope(
        messageId: String,
        targetDeviceId: String,
        expectedGeneration: Int,
        command: [String: Any]
    ) {
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": messageId,
            "type": "command",
            "targetDeviceId": targetDeviceId,
            "expectedGeneration": expectedGeneration,
            "command": command,
        ]
        sendEnvelope(env)
    }

    private func handleNativeCommandAck(_ env: [String: Any]) -> Bool {
        guard let messageId = env["messageId"] as? String,
              let pending = pendingNativeCommands.removeValue(forKey: messageId) else {
            return false
        }
        let result = env["result"] as? [String: Any]
        let isStaleEpoch = result?["status"] as? String == "error" &&
            result?["code"] as? String == "stale_epoch"
        guard isStaleEpoch, !pending.attemptedStaleRetry else {
            return true
        }
        guard let generation = deviceGenerations[pending.targetDeviceId] else {
            return true
        }

        let retryMessageId = UUID().uuidString
        pendingNativeCommands[retryMessageId] = PendingNativeCommand(
            targetDeviceId: pending.targetDeviceId,
            command: pending.command,
            attemptedStaleRetry: true
        )
        sendCommandEnvelope(
            messageId: retryMessageId,
            targetDeviceId: pending.targetDeviceId,
            expectedGeneration: generation,
            command: pending.command
        )
        return true
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
