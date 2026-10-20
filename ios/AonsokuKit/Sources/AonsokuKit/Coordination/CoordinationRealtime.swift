import Foundation
import AVFoundation
import UIKit

protocol CoordinationRealtimeTransport: AnyObject {
    var onStateChange: ((String) -> Void)? { get set }
    var onEnvelope: ((String) -> Void)? { get set }
    var onCommandAck: ((String, String) -> Void)? { get set }
    var onReconnectNeeded: ((Int) -> Void)? { get set }
    var onRemoteCommandExecuted: (([String: Any], String?) -> Void)? { get set }

    func connect(
        wsUrl: String,
        ticket: String,
        deviceId: String,
        capabilities: Int,
        protocolVersion: Int,
        lastSeq: Int
    ) throws

    func disconnect()
    func scheduleReconnect()
    func sendCommand(
        _ command: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int,
        messageId: String?
    )
    func sendControlSessionBegin(targetDeviceId: String)
    func sendControlSessionEnd()
    func requestSnapshots()
    func requestHandoffCandidateFromCache(sourceDeviceId: String) throws
    func generation(for: String) -> Int?
    var lastSeq: Int { get }
    func resetSequence()
    func didEnterBackground()
    func willEnterForeground()
    func willTerminate()
    func sendCommandFromNative(
        targetDeviceId: String,
        expectedGeneration: Int?,
        command: [String: Any]
    ) -> Bool
    func publishNativePlaybackSnapshot(onlyWhenPlaying: Bool) -> Bool
}

private struct PendingNativeCommand {
    let targetDeviceId: String
    let command: [String: Any]
    let attemptedStaleRetry: Bool
}

struct CoordinationReconnectPolicy: Equatable {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let maxAttempts: Int

    init(
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 30,
        maxAttempts: Int = 10
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    func next(after attempts: Int) -> (attempt: Int, delay: TimeInterval) {
        let attempt = min(max(attempts + 1, 1), maxAttempts)
        let delay = min(baseDelay * pow(2, Double(attempt - 1)), maxDelay)
        return (attempt, delay)
    }

    func permitsReconnect(
        manualDisconnect: Bool,
        isAppInBackground: Bool
    ) -> Bool {
        !manualDisconnect && !isAppInBackground
    }
}

/// Real-time WebSocket transport for coordination — maintains a connection
/// to the coordination server, bridging remote commands and handoff events
/// to the audio service (design §8, §9, §10, §11).
///
/// iOS may suspend or close WebSockets in the background even while audio is
/// active. The app lifecycle therefore stops foreground heartbeats on
/// background entry and validates the transport with a ping on foreground
/// entry. A missing transport repeatedly requests a fresh ticket using capped
/// exponential backoff.
///
/// All methods must be called on the main thread; all callbacks are delivered
/// on the main thread.
///
/// Owned by CoordinationService; iOS lifecycle is managed by AppLifecycleService.
final class CoordinationRealtime: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate, CoordinationRealtimeTransport {
    internal var reconnectPolicy = CoordinationReconnectPolicy()
    internal var sessionFactory: (
        URLSessionConfiguration,
        URLSessionDelegate
    ) -> URLSession = { configuration, delegate in
        URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: OperationQueue.main
        )
    }

    /// Called when the connection state changes (connecting, connected, disconnected, etc).
    /// Invoked on the main thread with the state string.
    var onStateChange: ((String) -> Void)?

    /// Called when an envelope is received or sent.
    /// Invoked on the main thread with the raw envelope JSON string.
    var onEnvelope: ((String) -> Void)?

    /// Called when a command acknowledgment is received.
    /// Invoked on the main thread with (messageId, resultJson).
    var onCommandAck: ((String, String) -> Void)?

    /// Called when reconnection is needed.
    /// Invoked on the main thread with the attempt number.
    var onReconnectNeeded: ((Int) -> Void)?

    /// Called when a remote command is executed on this device.
    /// Invoked on the main thread with the command dict and source device id.
    var onRemoteCommandExecuted: (([String: Any], String?) -> Void)?

    internal static func buildHeartbeatEnvelope(
        protocolVersion: Int
    ) -> [String: Any] {
        [
            "version": protocolVersion,
            "messageId": UUID().uuidString,
            "type": "heartbeat",
        ]
    }

    internal static func buildHelloEnvelope(
        protocolVersion: Int,
        capabilities: Int,
        deviceId: String,
        ticket: String,
        lastSeq: Int
    ) -> [String: Any] {
        [
            "version": protocolVersion,
            "messageId": UUID().uuidString,
            "type": "hello",
            "protocolVersion": protocolVersion,
            "capabilities": capabilities,
            "deviceId": deviceId,
            "ticket": ticket,
            "lastSeq": lastSeq,
        ]
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
    private(set) var deviceId: String?
    private var capabilities: Int = 0
    private var protocolVersion: Int = 1
    private var currentTicket: String?
    private var connectLastSeq: Int = 0
    private var resumeSeq: Int64 = 0
    private var nativeSessionId = UUID().uuidString
    private var nativeGeneration = 1
    private var handoffPreparing = false
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
    /// §9.1 dedup cache for incoming envelopes.
    private var dedupCache = CoordinationDedup(max: 200)
    /// §9.2 sequence tracker — highest server seq processed.
    private var seqTracker = CoordinationSeqTracker()

    /// Audio-session observers mirroring AonsokuNativeAudioPlugin's pattern.
    /// When the audio session is active the coordination URLSession is kept
    /// eligible for background execution; when interrupted, the plugin
    /// degrades gracefully.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var audioStateDidChangeObserver: NSObjectProtocol?
    private var isAppInBackground = false

    // MARK: - Lifecycle

    override init() {
        super.init()
        isAppInBackground = Thread.isMainThread ? UIApplication.shared.applicationState == .background : false
        registerAudioSessionObservers()
    }

    deinit {
        removeAudioSessionObservers()
    }

    // MARK: - WebSocket Connection

    /// Connect to the coordination server with the given ticket.
    func connect(
        wsUrl: String,
        ticket: String,
        deviceId: String,
        capabilities: Int,
        protocolVersion: Int,
        lastSeq: Int
    ) throws {
        // Do not create a second socket when lifecycle validation finds the
        // existing connection healthy.
        if let task = self.webSocketTask, !self.isConnecting, task.state == .running {
            return
        }

        let urlWithTicket = CoordinationURL.buildTicketUrl(wsUrl, ticket: ticket)
        guard let url = URL(string: urlWithTicket) else {
            throw CoordinationError(code: CoordinationErrorCode.badMessage, reason: "invalid URL")
        }

        self.manualDisconnect = false
        let savedReconnectAttempts = self.reconnectAttempts
        self.disconnectInternal()
        self.reconnectAttempts = savedReconnectAttempts
        self.deviceId = deviceId
        self.currentTicket = ticket
        self.capabilities = capabilities
        self.protocolVersion = protocolVersion
        self.connectLastSeq = lastSeq
        self.resumeSeq = Int64(lastSeq)
        self.seqTracker = CoordinationSeqTracker()
        self.seqTracker.observe(Int64(lastSeq))
        // The dedup cache is per-connection; clear it so a reconnect does
        // not falsely skip messages from the new connection.
        self.dedupCache.clear()

        // WebSocket tasks use a normal session. Background URLSession supports
        // transfer tasks, not an indefinitely-live realtime transport.
        let config = URLSessionConfiguration.default
        config.shouldUseExtendedBackgroundIdleMode = true
        config.waitsForConnectivity = true
        self.session = sessionFactory(config, self)

        let task = self.session?.webSocketTask(with: url)
        self.webSocketTask = task
        task?.resume()

        self.isConnecting = true
        self.notifyState("connecting")
    }

    /// Disconnect from the coordination server.
    func disconnect() {
        self.manualDisconnect = true
        self.disconnectInternal()
        self.reconnectAttempts = 0
    }

    /// Schedule a reconnection attempt (internal).
    func scheduleReconnect() {
        scheduleReconnectInternal()
    }

    /// Current connection state description: "disconnected", "connecting", "connected", "reconnecting", or "interrupted".
    var connectionStateDescription: String {
        if self.webSocketTask == nil {
            return "disconnected"
        } else if self.isConnecting {
            return "connecting"
        } else {
            return "connected"
        }
    }

    /// Send a command to a target device.
    func sendCommand(
        _ command: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int,
        messageId: String?
    ) {
        // §9.1: the caller may supply a messageId to match the command to a
        // pending-ack promise. Fall back to a generated UUID.
        activeRemoteControlTargetDeviceId = targetDeviceId
        let suppliedMessageId = messageId
        let finalMessageId = suppliedMessageId ?? UUID().uuidString
        if suppliedMessageId == nil {
            pendingNativeCommands[finalMessageId] = PendingNativeCommand(
                targetDeviceId: targetDeviceId,
                command: command,
                attemptedStaleRetry: false
            )
        }
        sendCommandEnvelope(
            messageId: finalMessageId,
            targetDeviceId: targetDeviceId,
            expectedGeneration: expectedGeneration,
            command: command
        )
    }

    /// Send a command from the active control session.
    func sendActiveControlCommand(_ command: [String: Any]) throws {
        guard let targetDeviceId = activeRemoteControlTargetDeviceId else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected, reason: "no active control session")
        }
        guard sendCommandFromNative(
            targetDeviceId: targetDeviceId,
            expectedGeneration: deviceGenerations[targetDeviceId],
            command: command
        ) else {
            throw CoordinationError(code: CoordinationErrorCode.notConnected, reason: "native coordination is not connected")
        }
    }

    /// Begin a remote control session with a target device.
    func sendControlSessionBegin(targetDeviceId: String) {
        activeRemoteControlTargetDeviceId = targetDeviceId
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "control_session_begin",
            "targetDeviceId": targetDeviceId,
        ]
        sendEnvelope(env)
    }

    /// End the remote control session.
    func sendControlSessionEnd() {
        activeRemoteControlTargetDeviceId = nil
        AudioCoordinationBridge.clearRemotePlaybackProjection()
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "control_session_end",
        ]
        sendEnvelope(env)
    }

    /// Request a handoff candidate from cache for the given source device.
    func requestHandoffCandidateFromCache(sourceDeviceId: String) throws {
        guard sendHandoffCandidateRequestFromCache(sourceDeviceId: sourceDeviceId) else {
            throw CoordinationError(code: CoordinationErrorCode.snapshotExpired, reason: "missing cached handoff snapshot")
        }
        pendingNativeHandoffSourceDeviceId = sourceDeviceId
        pendingNativeHandoffRetryWaitingForSnapshot = false
        pendingNativeHandoffRetryCount = 0
    }

    /// Request snapshots from all connected devices.
    func requestSnapshots() {
        let env: [String: Any] = [
            "version": self.protocolVersion,
            "messageId": UUID().uuidString,
            "type": "request_snapshots",
        ]
        sendEnvelope(env)
    }

    /// Get the active remote control target device ID.
    var activeControlTargetDeviceId: String? {
        activeRemoteControlTargetDeviceId
    }

    /// Get the generation for a given device ID.
    func generation(for deviceId: String) -> Int? {
        deviceGenerations[deviceId]
    }

    /// Get the snapshot revision for a given device ID.
    func snapshotRevision(for deviceId: String) -> Int? {
        deviceSnapshotRevisions[deviceId]
    }

    /// Get the last sequence number seen (for resume-friendly reconnects).
    var lastSeq: Int {
        Int(resumeSeq)
    }

    /// Reset the sequence tracker for a fresh connection.
    func resetSequence() {
        resumeSeq = 0
    }

    // MARK: - Lifecycle Handlers (called by AppLifecycleService)

    /// Called when the app enters the background.
    func didEnterBackground() {
        DispatchQueue.main.async {
            self.handleApplicationDidEnterBackground()
        }
    }

    /// Called when the app will enter the foreground.
    func willEnterForeground() {
        DispatchQueue.main.async {
            self.handleApplicationWillEnterForeground()
        }
    }

    /// Called when the app will terminate.
    func willTerminate() {
        DispatchQueue.main.async {
            self.handleApplicationWillTerminate()
        }
    }

    // MARK: - Public command dispatch (called by AudioService)

    /// Send a command from the active audio service.
    /// Returns true if the command was sent, false if coordination is not connected.
    internal func sendCommandFromNative(
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

    /// Publish a native playback snapshot.
    /// Returns true if the snapshot was sent, false otherwise.
    internal func publishNativePlaybackSnapshot(onlyWhenPlaying: Bool = false) -> Bool {
        if handoffPreparing { return false }
        guard self.webSocketTask != nil,
              let audioState = AudioCoordinationBridge.getFullState(),
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

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === self.webSocketTask else { return }
        self.isConnecting = false
        self.reconnectAttempts = 0
        self.sendHello()
        if !isAppInBackground {
            self.startHeartbeat()
            self.startSnapshotHeartbeat()
        }
        self.notifyState("connected")
        self.receiveMessage()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleTransportClosed(webSocketTask)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil, let webSocketTask = task as? URLSessionWebSocketTask else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.handleTransportClosed(webSocketTask)
        }
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

        if audioStateDidChangeObserver == nil {
            // AudioService posts this from its state queue while the main
            // thread may be waiting on that queue, so the observer runs on
            // the posting thread and only schedules the publish on main.
            audioStateDidChangeObserver = center.addObserver(
                forName: .aonsokuAudioStateDidChange,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard notification.object is AudioService else { return }
                DispatchQueue.main.async { [weak self] in
                    _ = self?.publishNativePlaybackSnapshot()
                }
            }
        }

    }

    private func removeAudioSessionObservers() {
        let center = NotificationCenter.default
        for observer in [
            interruptionObserver,
            routeChangeObserver,
            audioStateDidChangeObserver,
        ] {
            if let observer { center.removeObserver(observer) }
        }
        interruptionObserver = nil
        routeChangeObserver = nil
        audioStateDidChangeObserver = nil
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            self.heartbeatTimer?.invalidate()
            self.heartbeatTimer = nil
            self.stopSnapshotHeartbeat()
            self.notifyState("interrupted")
        case .ended:
            if self.webSocketTask?.state == .running && !isAppInBackground {
                self.startHeartbeat()
                self.startSnapshotHeartbeat()
                self.notifyState("connected")
            } else if !self.manualDisconnect && !isAppInBackground {
                self.notifyState("disconnected")
                self.scheduleReconnect()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Private Helpers

    private func handleApplicationDidEnterBackground() {
        isAppInBackground = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        stopSnapshotHeartbeat()
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func handleApplicationWillEnterForeground() {
        isAppInBackground = false
        guard !manualDisconnect else { return }
        guard let task = webSocketTask, task.state == .running else {
            notifyState("disconnected")
            scheduleReconnect()
            return
        }
        task.sendPing { [weak self, weak task] error in
            DispatchQueue.main.async {
                guard let self, let task, task === self.webSocketTask else {
                    return
                }
                if error == nil {
                    self.reconnectAttempts = 0
                    self.startHeartbeat()
                    self.startSnapshotHeartbeat()
                    self.notifyState("connected")
                } else {
                    self.handleTransportClosed(task)
                }
            }
        }
    }

    private func handleApplicationWillTerminate() {
        manualDisconnect = true
        disconnectInternal()
    }

    private func handleTransportClosed(_ task: URLSessionWebSocketTask) {
        guard task === webSocketTask else { return }
        isConnecting = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        stopSnapshotHeartbeat()
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        notifyState("disconnected")
        if !manualDisconnect && !isAppInBackground { scheduleReconnect() }
    }

    private func disconnectInternal() {
        if handoffPreparing {
            handoffPreparing = false
            AudioCoordinationBridge.rollbackHandoffPlayback()
        }
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
        self.stopSnapshotHeartbeat()
        self.reconnectWorkItem?.cancel()
        self.reconnectWorkItem = nil
        self.webSocketTask?.cancel()
        self.webSocketTask = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.isConnecting = false
        self.currentTicket = nil
        // §9.1: clear the dedup cache so a reconnect does not falsely skip
        // messages from the new connection.
        self.dedupCache.clear()
        // §9.2: reset the seq tracker but NOT resumeSeq, so resumeSeq
        // survives reconnects when the connection is recovered.
        self.seqTracker.reset()
    }

    private func startHeartbeat() {
        self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sendEnvelope(Self.buildHeartbeatEnvelope(
                protocolVersion: self.protocolVersion
            ))
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
        self.sendEnvelope(Self.buildHelloEnvelope(
            protocolVersion: self.protocolVersion,
            capabilities: self.capabilities,
            deviceId: deviceId,
            ticket: ticket,
            lastSeq: self.connectLastSeq
        ))
    }

    private func receiveMessage() {
        guard let task = self.webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self = self, self.webSocketTask === task else { return }
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
                DispatchQueue.main.async {
                    self.handleTransportClosed(task)
                }
            }
        }
    }

    private func dispatchEnvelope(_ json: String) {
        // Parse once to extract routing metadata, then forward the raw JSON
        // to the WebView so it can re-parse into the full Envelope type.
        if let dict = JSONUtilities.parse(json) {
            // §9.2: track the incoming seq on every envelope.
            if let seq = CoordinationEnvelope.seq(dict) {
                self.seqTracker.observe(seq)
                self.resumeSeq = max(self.resumeSeq, seq)
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
                        AudioCoordinationBridge.clearRemotePlaybackProjection()
                    } else if let snapshot = dict["snapshot"] as? [String: Any] {
                        AudioCoordinationBridge.updateRemotePlaybackProjection(
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
                        self.onCommandAck?(messageId, result)
                    }
                }
            }
            if let type = dict["type"] as? String,
               type == "command",
               let command = dict["command"] as? [String: Any],
               AudioCoordinationBridge.executeRemoteControlCommand(command) {
                if let messageId = dict["messageId"] as? String {
                    self.sendEnvelope(Self.buildCommandAckEnvelope(
                        protocolVersion: self.protocolVersion,
                        messageId: messageId
                    ))
                }
                let sourceDeviceId = dict["sourceDeviceId"] as? String
                DispatchQueue.main.async {
                    self.onRemoteCommandExecuted?(command, sourceDeviceId)
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
                if let audioState = AudioCoordinationBridge.pauseAndGetFullState(),
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
                handoffPreparing = true
                let connection = webSocketTask
                let snapshot = dict["snapshot"] as? [String: Any]
                let transactionId = dict["transactionId"] as? String ?? ""
                let sourceDeviceId = dict["sourceDeviceId"] as? String ?? ""
                let sessionId = dict["sessionId"] as? String ?? ""
                let canPrepare = snapshot != nil &&
                    !transactionId.isEmpty &&
                    !sourceDeviceId.isEmpty &&
                    !sessionId.isEmpty
                let accepted = canPrepare && AudioCoordinationBridge.prepareHandoffPlayback(
                    snapshot: snapshot ?? [:],
                    autoplay: false,
                    completion: { prepared in
                        guard self.webSocketTask === connection, self.handoffPreparing else { return }
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
                            self.handoffPreparing = false
                            AudioCoordinationBridge.rollbackHandoffPlayback()
                            self.sendEnvelope(Self.buildHandoffFailedEnvelope(
                                protocolVersion: self.protocolVersion,
                                transactionId: transactionId,
                                code: "unsupported_media"
                            ))
                        }
                    }
                )
                if !accepted && !transactionId.isEmpty {
                    handoffPreparing = false
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
               let snapshot = dict["snapshot"] as? [String: Any] {
                nativeSessionId = snapshot["sessionId"] as? String ?? nativeSessionId
                nativeGeneration = dict["newGeneration"] as? Int ?? nativeGeneration
                nativeSnapshotRevision = 0
                let accepted = AudioCoordinationBridge.prepareHandoffPlayback(
                   snapshot: snapshot,
                   autoplay: true,
                   completion: { prepared in
                       self.handoffPreparing = false
                       if prepared {
                           DispatchQueue.main.async {
                               _ = self.publishNativePlaybackSnapshot()
                               self.onEnvelope?(json)
                           }
                       } else {
                           AudioCoordinationBridge.rollbackHandoffPlayback()
                           let failure = Self.buildHandoffFailedEnvelope(
                               protocolVersion: self.protocolVersion,
                               transactionId: dict["transactionId"] as? String ?? "",
                               code: "unsupported_media"
                           )
                           if let data = try? JSONSerialization.data(withJSONObject: failure),
                              let failureJson = String(data: data, encoding: .utf8) {
                               DispatchQueue.main.async {
                                   self.onEnvelope?(failureJson)
                               }
                           }
                       }
                   }
                )
                pendingNativeHandoffSourceDeviceId = nil
                pendingNativeHandoffRetryWaitingForSnapshot = false
                pendingNativeHandoffRetryCount = 0
                if accepted {
                    return
                }
            }
            if let type = dict["type"] as? String, type == "handoff_failed" {
                handoffPreparing = false
                AudioCoordinationBridge.rollbackHandoffPlayback()
                pendingNativeHandoffSourceDeviceId = nil
                pendingNativeHandoffRetryWaitingForSnapshot = false
                pendingNativeHandoffRetryCount = 0
            }
            if let type = dict["type"] as? String,
               type == "session_superseded" {
                nativeSessionId = UUID().uuidString
                nativeGeneration = 1
                nativeSnapshotRevision = 0
                _ = AudioCoordinationBridge.executeRemoteControlCommand(["type": "pause"])
            }
        }
        DispatchQueue.main.async {
            self.onEnvelope?(json)
        }
    }

    private func sendEnvelope(_ env: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: env),
              let string = String(data: data, encoding: .utf8) else { return }
        self.webSocketTask?.send(.string(string)) { _ in }
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

    private func scheduleReconnectInternal() {
        guard reconnectPolicy.permitsReconnect(
            manualDisconnect: manualDisconnect,
            isAppInBackground: isAppInBackground
        ) else { return }
        reconnectWorkItem?.cancel()
        let next = reconnectPolicy.next(after: reconnectAttempts)
        self.reconnectAttempts = next.attempt
        // Tickets expire in 30s so the native layer only emits the request;
        // the WebView performs the reconnect after refreshing the ticket.
        let attempt = next.attempt
        let delay = next.delay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.notifyReconnectNeeded(attempt: attempt)
            if self.webSocketTask == nil && !self.manualDisconnect {
                self.scheduleReconnect()
            }
        }
        self.reconnectWorkItem = workItem
        self.notifyState("reconnecting")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func notifyReconnectNeeded(attempt: Int) {
        DispatchQueue.main.async {
            self.onReconnectNeeded?(attempt)
        }
    }

    private func notifyState(_ state: String) {
        DispatchQueue.main.async {
            self.onStateChange?(state)
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

enum CoordinationEnvelope {
    static func seq(_ envelope: [String: Any]) -> Int64? {
        switch envelope["seq"] {
        case let value as Int64: return value
        case let value as Int: return Int64(value)
        case let value as Double: return Int64(value)
        case let value as String: return Int64(value)
        default: return nil
        }
    }

    static func messageId(_ envelope: [String: Any]) -> String? {
        envelope["messageId"] as? String
    }

    static func type(_ envelope: [String: Any]) -> String? {
        envelope["type"] as? String
    }
}

/// Append the one-time WebSocket ticket as a URL-encoded query parameter so
/// tickets containing &/=/?/# do not break the URL.
enum CoordinationURL {
    static func buildTicketUrl(_ wsUrl: String, ticket: String) -> String {
        let separator = wsUrl.contains("?") ? "&" : "?"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        let encoded = ticket.addingPercentEncoding(
            withAllowedCharacters: allowed,
        ) ?? ticket
        return wsUrl + separator + "ticket=" + encoded
    }
}
