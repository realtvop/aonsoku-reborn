import Foundation

// Typed value contract for cross-device coordination. The wire format mirrors
// `src/coordination/types.ts` (protocol version 1); JSON helpers convert to
// and from the `[String: Any]` envelopes used on the WebSocket.

// MARK: - Connection

public enum CoordinationConnectionState: String, Sendable, Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case reconnecting
    case error
}

public enum CoordinationCapabilities {
    public static let history = 1
    public static let observe = 2
    public static let control = 4
    public static let handoff = 8
    public static let all = history | observe | control | handoff
}

public struct CoordinationConfig: Codable, Equatable, Sendable {
    public var serverUrl: String
    public var identityUrl: String

    public init(serverUrl: String, identityUrl: String) {
        self.serverUrl = serverUrl
        self.identityUrl = identityUrl
    }
}

// MARK: - Devices

public struct CoordinationDevice: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var clientVersion: String?
    public var capabilities: Int
    public var createdAt: String
    public var lastOnlineAt: String?
    public var revokedAt: String?
    public var historySyncCursor: Int
    public var legacyHistoryImported: Bool
    public var isControlling: Bool

    public init(
        id: String,
        name: String,
        platform: String,
        clientVersion: String? = nil,
        capabilities: Int = CoordinationCapabilities.all,
        createdAt: String = "",
        lastOnlineAt: String? = nil,
        revokedAt: String? = nil,
        historySyncCursor: Int = 0,
        legacyHistoryImported: Bool = false,
        isControlling: Bool = false
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.clientVersion = clientVersion
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.lastOnlineAt = lastOnlineAt
        self.revokedAt = revokedAt
        self.historySyncCursor = historySyncCursor
        self.legacyHistoryImported = legacyHistoryImported
        self.isControlling = isControlling
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        capabilities = try c.decodeIfPresent(Int.self, forKey: .capabilities) ?? 0
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastOnlineAt = try c.decodeIfPresent(String.self, forKey: .lastOnlineAt)
        revokedAt = try c.decodeIfPresent(String.self, forKey: .revokedAt)
        historySyncCursor = try c.decodeIfPresent(Int.self, forKey: .historySyncCursor) ?? 0
        legacyHistoryImported = try c.decodeIfPresent(
            Bool.self,
            forKey: .legacyHistoryImported
        ) ?? false
        isControlling = try c.decodeIfPresent(Bool.self, forKey: .isControlling) ?? false
    }

    public var lastOnlineDate: Date? { CoordinationDate.parse(lastOnlineAt) }
    public var createdDate: Date? { CoordinationDate.parse(createdAt) }
    public var isRevoked: Bool { revokedAt != nil }

    public init?(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let device = try? JSONDecoder().decode(CoordinationDevice.self, from: data) else {
            return nil
        }
        self = device
    }
}

public enum CoordinationDate {
    /// Parses the RFC 3339 timestamps the coordination servers emit, with or
    /// without fractional seconds.
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// MARK: - Playback snapshot

public enum CoordinationRepeatMode: String, Codable, Sendable, CaseIterable {
    case off
    case one
    case all
}

public struct CoordinationPlaybackSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    public var logicalPlaybackSessionId: String
    public var mediaKind: String
    public var songId: String
    public var progressSeconds: Double
    public var durationSeconds: Double
    public var isPlaying: Bool
    /// Seconds since the Unix epoch.
    public var sampledAt: Double
    public var contextQueue: [String]
    public var contextIndex: Int?
    /// `"<type>:<id>"`, for example `"album:42"`.
    public var sourceId: String?
    public var sourceName: String?
    public var userQueue: [String]
    public var inUserQueue: Bool
    public var restorePrevious: [String]
    public var shuffle: Bool
    public var repeatMode: CoordinationRepeatMode
    public var volume: Double?
    public var accumulatedPlaySeconds: Double
    public var historyWritten: Bool
    public var nowPlayingSent: Bool
    public var scrobbleSent: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId
        case logicalPlaybackSessionId
        case mediaKind
        case songId
        case progressSeconds
        case durationSeconds
        case isPlaying
        case sampledAt
        case contextQueue
        case contextIndex
        case sourceId
        case sourceName
        case userQueue
        case inUserQueue
        case restorePrevious
        case shuffle
        case repeatMode = "repeat"
        case volume
        case accumulatedPlaySeconds
        case historyWritten
        case nowPlayingSent
        case scrobbleSent
    }

    public init(
        sessionId: String,
        logicalPlaybackSessionId: String? = nil,
        mediaKind: String = "song",
        songId: String,
        progressSeconds: Double = 0,
        durationSeconds: Double = 0,
        isPlaying: Bool = false,
        sampledAt: Double = Date().timeIntervalSince1970,
        contextQueue: [String] = [],
        contextIndex: Int? = nil,
        sourceId: String? = nil,
        sourceName: String? = nil,
        userQueue: [String] = [],
        inUserQueue: Bool = false,
        restorePrevious: [String] = [],
        shuffle: Bool = false,
        repeatMode: CoordinationRepeatMode = .off,
        volume: Double? = nil,
        accumulatedPlaySeconds: Double = 0,
        historyWritten: Bool = false,
        nowPlayingSent: Bool = false,
        scrobbleSent: Bool = false
    ) {
        self.sessionId = sessionId
        self.logicalPlaybackSessionId = logicalPlaybackSessionId ?? sessionId
        self.mediaKind = mediaKind
        self.songId = songId
        self.progressSeconds = progressSeconds
        self.durationSeconds = durationSeconds
        self.isPlaying = isPlaying
        self.sampledAt = sampledAt
        self.contextQueue = contextQueue
        self.contextIndex = contextIndex
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.userQueue = userQueue
        self.inUserQueue = inUserQueue
        self.restorePrevious = restorePrevious
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.volume = volume
        self.accumulatedPlaySeconds = accumulatedPlaySeconds
        self.historyWritten = historyWritten
        self.nowPlayingSent = nowPlayingSent
        self.scrobbleSent = scrobbleSent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        logicalPlaybackSessionId = try c.decodeIfPresent(
            String.self,
            forKey: .logicalPlaybackSessionId
        ) ?? sessionId
        mediaKind = try c.decodeIfPresent(String.self, forKey: .mediaKind) ?? "song"
        songId = try c.decodeIfPresent(String.self, forKey: .songId) ?? ""
        progressSeconds = try c.decodeIfPresent(Double.self, forKey: .progressSeconds) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        sampledAt = try c.decodeIfPresent(Double.self, forKey: .sampledAt) ?? 0
        contextQueue = try c.decodeIfPresent([String].self, forKey: .contextQueue) ?? []
        contextIndex = try c.decodeIfPresent(Int.self, forKey: .contextIndex)
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        userQueue = try c.decodeIfPresent([String].self, forKey: .userQueue) ?? []
        inUserQueue = try c.decodeIfPresent(Bool.self, forKey: .inUserQueue) ?? false
        restorePrevious = try c.decodeIfPresent([String].self, forKey: .restorePrevious) ?? []
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        repeatMode = (try? c.decodeIfPresent(CoordinationRepeatMode.self, forKey: .repeatMode))
            .flatMap { $0 } ?? .off
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        accumulatedPlaySeconds = try c.decodeIfPresent(
            Double.self,
            forKey: .accumulatedPlaySeconds
        ) ?? 0
        historyWritten = try c.decodeIfPresent(Bool.self, forKey: .historyWritten) ?? false
        nowPlayingSent = try c.decodeIfPresent(Bool.self, forKey: .nowPlayingSent) ?? false
        scrobbleSent = try c.decodeIfPresent(Bool.self, forKey: .scrobbleSent) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(logicalPlaybackSessionId, forKey: .logicalPlaybackSessionId)
        try c.encode(mediaKind, forKey: .mediaKind)
        try c.encode(songId, forKey: .songId)
        try c.encode(progressSeconds, forKey: .progressSeconds)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(isPlaying, forKey: .isPlaying)
        try c.encode(sampledAt, forKey: .sampledAt)
        try c.encode(contextQueue, forKey: .contextQueue)
        try c.encode(contextIndex, forKey: .contextIndex)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(userQueue, forKey: .userQueue)
        try c.encode(inUserQueue, forKey: .inUserQueue)
        try c.encode(restorePrevious, forKey: .restorePrevious)
        try c.encode(shuffle, forKey: .shuffle)
        try c.encode(repeatMode, forKey: .repeatMode)
        try c.encode(volume, forKey: .volume)
        try c.encode(accumulatedPlaySeconds, forKey: .accumulatedPlaySeconds)
        try c.encode(historyWritten, forKey: .historyWritten)
        try c.encode(nowPlayingSent, forKey: .nowPlayingSent)
        try c.encode(scrobbleSent, forKey: .scrobbleSent)
    }

    /// Decodes a snapshot from a WebSocket payload dictionary.
    public init?(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let snapshot = try? JSONDecoder().decode(
                  CoordinationPlaybackSnapshot.self,
                  from: data
              ),
              !snapshot.songId.isEmpty else {
            return nil
        }
        self = snapshot
    }

    /// The wire dictionary, with `null` for absent optionals.
    public var jsonObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// Parses `sourceId` (`"album:42"`) into its type and id.
    public var source: (type: String, id: String)? {
        guard let sourceId,
              let separator = sourceId.firstIndex(of: ":") else { return nil }
        let type = String(sourceId[..<separator])
        let id = String(sourceId[sourceId.index(after: separator)...])
        guard !type.isEmpty, !id.isEmpty else { return nil }
        return (type, id)
    }
}

/// A remote device's last published playback, as projected by the server.
public struct CoordinationDeviceSnapshot: Equatable, Sendable {
    public var deviceId: String
    public var snapshot: CoordinationPlaybackSnapshot
    public var isOnline: Bool
    public var generation: Int
    public var snapshotRevision: Int
    /// Server clock (seconds since the Unix epoch) when the projection was sent.
    public var serverTime: Double
    /// Server clock (seconds) when the source device last confirmed the snapshot.
    public var lastConfirmedAt: Double
    /// `ProcessInfo.systemUptime` when this device received the projection.
    public var receivedAt: TimeInterval

    public init(
        deviceId: String,
        snapshot: CoordinationPlaybackSnapshot,
        isOnline: Bool,
        generation: Int,
        snapshotRevision: Int,
        serverTime: Double,
        lastConfirmedAt: Double,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.deviceId = deviceId
        self.snapshot = snapshot
        self.isOnline = isOnline
        self.generation = generation
        self.snapshotRevision = snapshotRevision
        self.serverTime = serverTime
        self.lastConfirmedAt = lastConfirmedAt
        self.receivedAt = receivedAt
    }

    /// Wall-clock time of the last confirmation, for "updated … ago" labels.
    public var lastConfirmedDate: Date { Date(timeIntervalSince1970: lastConfirmedAt) }

    /// Mirrors `src/coordination/progress.ts`: paused snapshots stay put;
    /// playing snapshots advance by server-side staleness plus local elapsed
    /// time, clamped to the duration.
    public func projectedProgress(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double {
        let duration = snapshot.durationSeconds
        let clamp: (Double) -> Double = { value in
            duration > 0 ? min(max(value, 0), duration) : max(value, 0)
        }
        guard snapshot.isPlaying else { return clamp(snapshot.progressSeconds) }
        let serverLag = max(0, serverTime - lastConfirmedAt)
        let localElapsed = max(0, now - receivedAt)
        return clamp(snapshot.progressSeconds + serverLag + localElapsed)
    }
}

// MARK: - Remote commands

public enum CoordinationRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case previous
    case next
    case seek(seconds: Double)
    case setVolume(Double)
    case setShuffle(Bool)
    case setRepeat(CoordinationRepeatMode)
    case toggleLike
    case playSong(songId: String)
    case playAlbum(albumId: String, index: Int? = nil, shuffle: Bool? = nil)
    case playPlaylist(playlistId: String, index: Int? = nil, shuffle: Bool? = nil)
    case addToQueueNext(songIds: [String])
    case addToQueueLast(songIds: [String])
    case removeFromQueue(songIds: [String])
    case reorderQueue(from: Int, to: Int)
    case clearQueue
    case playAtIndex(songIds: [String], index: Int)

    /// The snake_case wire dictionary, e.g. `["type": "seek", "seconds": 12]`.
    public var jsonObject: [String: Any] {
        switch self {
        case .play: return ["type": "play"]
        case .pause: return ["type": "pause"]
        case .togglePlayPause: return ["type": "toggle_play_pause"]
        case .previous: return ["type": "previous"]
        case .next: return ["type": "next"]
        case let .seek(seconds): return ["type": "seek", "seconds": seconds]
        case let .setVolume(volume): return ["type": "set_volume", "volume": volume]
        case let .setShuffle(enabled): return ["type": "set_shuffle", "enabled": enabled]
        case let .setRepeat(mode): return ["type": "set_repeat", "mode": mode.rawValue]
        case .toggleLike: return ["type": "toggle_like"]
        case let .playSong(songId): return ["type": "play_song", "song_id": songId]
        case let .playAlbum(albumId, index, shuffle):
            var object: [String: Any] = ["type": "play_album", "album_id": albumId]
            if let index { object["index"] = index }
            if let shuffle { object["shuffle"] = shuffle }
            return object
        case let .playPlaylist(playlistId, index, shuffle):
            var object: [String: Any] = ["type": "play_playlist", "playlist_id": playlistId]
            if let index { object["index"] = index }
            if let shuffle { object["shuffle"] = shuffle }
            return object
        case let .addToQueueNext(songIds):
            return ["type": "add_to_queue_next", "song_ids": songIds]
        case let .addToQueueLast(songIds):
            return ["type": "add_to_queue_last", "song_ids": songIds]
        case let .removeFromQueue(songIds):
            return ["type": "remove_from_queue", "song_ids": songIds]
        case let .reorderQueue(from, to):
            return ["type": "reorder_queue", "from": from, "to": to]
        case .clearQueue: return ["type": "clear_queue"]
        case let .playAtIndex(songIds, index):
            return ["type": "play_at_index", "song_ids": songIds, "index": index]
        }
    }

    public init?(json: [String: Any]) {
        func number(_ key: String) -> Double? {
            (json[key] as? NSNumber)?.doubleValue
        }
        func integer(_ key: String) -> Int? {
            (json[key] as? NSNumber)?.intValue
        }
        func strings(_ key: String) -> [String]? {
            json[key] as? [String]
        }
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "play": self = .play
        case "pause": self = .pause
        case "toggle_play_pause": self = .togglePlayPause
        case "previous": self = .previous
        case "next": self = .next
        case "seek":
            guard let seconds = number("seconds") else { return nil }
            self = .seek(seconds: seconds)
        case "set_volume":
            guard let volume = number("volume") else { return nil }
            self = .setVolume(volume)
        case "set_shuffle":
            guard let enabled = json["enabled"] as? Bool else { return nil }
            self = .setShuffle(enabled)
        case "set_repeat":
            guard let raw = json["mode"] as? String,
                  let mode = CoordinationRepeatMode(rawValue: raw) else { return nil }
            self = .setRepeat(mode)
        case "toggle_like": self = .toggleLike
        case "play_song":
            guard let songId = json["song_id"] as? String else { return nil }
            self = .playSong(songId: songId)
        case "play_album":
            guard let albumId = json["album_id"] as? String else { return nil }
            self = .playAlbum(
                albumId: albumId,
                index: integer("index"),
                shuffle: json["shuffle"] as? Bool
            )
        case "play_playlist":
            guard let playlistId = json["playlist_id"] as? String else { return nil }
            self = .playPlaylist(
                playlistId: playlistId,
                index: integer("index"),
                shuffle: json["shuffle"] as? Bool
            )
        case "add_to_queue_next":
            guard let songIds = strings("song_ids") else { return nil }
            self = .addToQueueNext(songIds: songIds)
        case "add_to_queue_last":
            guard let songIds = strings("song_ids") else { return nil }
            self = .addToQueueLast(songIds: songIds)
        case "remove_from_queue":
            guard let songIds = strings("song_ids") else { return nil }
            self = .removeFromQueue(songIds: songIds)
        case "reorder_queue":
            guard let from = integer("from"), let to = integer("to") else { return nil }
            self = .reorderQueue(from: from, to: to)
        case "clear_queue": self = .clearQueue
        case "play_at_index":
            guard let songIds = strings("song_ids"), let index = integer("index") else {
                return nil
            }
            self = .playAtIndex(songIds: songIds, index: index)
        default:
            return nil
        }
    }
}

public enum CoordinationCommandResult: Equatable, Sendable {
    case ok
    case error(code: String, reason: String?)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

// MARK: - Errors

/// Error codes shared with the Rust and Workers servers.
public enum CoordinationErrorCode {
    public static let authenticationFailed = "authentication_failed"
    public static let deviceRevoked = "device_revoked"
    public static let targetOffline = "target_offline"
    public static let unsupportedMedia = "unsupported_media"
    public static let snapshotExpired = "snapshot_expired"
    public static let staleEpoch = "stale_epoch"
    public static let handoffConflict = "handoff_conflict"
    public static let sourceChanged = "source_changed"
    public static let sourcePauseTimeout = "source_pause_timeout"
    public static let payloadTooLarge = "payload_too_large"
    public static let protocolIncompatible = "protocol_incompatible"
    public static let rateLimited = "rate_limited"
    public static let badMessage = "bad_message"
    public static let notFound = "not_found"
    public static let forbidden = "forbidden"
    public static let `internal` = "internal"
    public static let challengeExpired = "challenge_expired"
    public static let ticketExpired = "ticket_expired"
    public static let invalidIdentity = "invalid_identity"
    public static let ssrfBlocked = "ssrf_blocked"
    public static let verificationFailed = "verification_failed"
    public static let notReady = "not_ready"
    /// Client-side: the service has no registered device or open socket.
    public static let notConnected = "not_connected"
    /// Client-side: no command acknowledgement arrived before the deadline.
    public static let timeout = "timeout"
    /// Client-side: required configuration or credentials are missing.
    public static let missingFields = "missing_fields"
}

public struct CoordinationError: LocalizedError, Equatable, Sendable {
    public var code: String
    public var reason: String?
    /// HTTP status when the error came from the REST API.
    public var status: Int?

    public init(code: String, reason: String? = nil, status: Int? = nil) {
        self.code = code
        self.reason = reason
        self.status = status
    }

    public var errorDescription: String? {
        if let reason, !reason.isEmpty { return reason }
        return code
    }
}

// MARK: - State and events

public struct CoordinationState: Equatable, Sendable {
    public var connectionState: CoordinationConnectionState
    public var config: CoordinationConfig?
    /// This device's registered id; nil until registration succeeds.
    public var deviceId: String?
    public var accountId: String?
    public var devices: [CoordinationDevice]
    /// Latest projection per remote device id.
    public var deviceSnapshots: [String: CoordinationDeviceSnapshot]
    /// Device currently driven through a remote-control session, if any.
    public var controlledDeviceId: String?
    /// When the device list last refreshed.
    public var lastSyncAt: Date?
    public var lastError: CoordinationError?

    public init(
        connectionState: CoordinationConnectionState = .disconnected,
        config: CoordinationConfig? = nil,
        deviceId: String? = nil,
        accountId: String? = nil,
        devices: [CoordinationDevice] = [],
        deviceSnapshots: [String: CoordinationDeviceSnapshot] = [:],
        controlledDeviceId: String? = nil,
        lastSyncAt: Date? = nil,
        lastError: CoordinationError? = nil
    ) {
        self.connectionState = connectionState
        self.config = config
        self.deviceId = deviceId
        self.accountId = accountId
        self.devices = devices
        self.deviceSnapshots = deviceSnapshots
        self.controlledDeviceId = controlledDeviceId
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
    }

    /// True once this device holds coordination tokens.
    public var isRegistered: Bool { deviceId != nil }
    public var isConnected: Bool { connectionState == .connected }
}

public enum CoordinationEvent: Sendable {
    /// Any change to `CoordinationService.state`; carries the new value.
    case stateChanged(CoordinationState)
    /// This device became the playback owner after a handoff.
    case handoffCommitted(
        transactionId: String,
        snapshot: CoordinationPlaybackSnapshot,
        newGeneration: Int
    )
    /// A handoff this device took part in failed; local playback was restored.
    case handoffFailed(transactionId: String?, code: String)
    /// Another device took over this device's playback session.
    case sessionSuperseded(supersededGeneration: Int, transferredToDevice: String?)
    /// A remote device's command was executed on this device.
    case remoteCommandExecuted(CoordinationRemoteCommand, sourceDeviceId: String?)
    case capabilityDisabled(feature: String)
    case error(CoordinationError)
}

public final class CoordinationObservation: @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    deinit { cancel() }

    public func cancel() {
        lock.lock()
        let shouldCancel = !isCancelled
        isCancelled = true
        lock.unlock()
        if shouldCancel { onCancel() }
    }
}
