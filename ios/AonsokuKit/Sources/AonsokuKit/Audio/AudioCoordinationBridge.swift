import Foundation

/// Bridge for coordination plugin to access audio service without importing the plugin.
enum AudioCoordinationBridge {
    // MARK: - Remote Control

    static func executeRemoteControlCommand(_ object: [String: Any]) -> Bool {
        guard let command = AudioPayloadCodec.decodeRemoteControlCommand(object) else {
            return false
        }
        return AppServices.shared.audio.execute(command)
    }

    // MARK: - State Retrieval

    static func getFullState() -> [String: Any]? {
        AppServices.shared.audio.fullState().map(encodeFullState)
    }

    static func pauseAndGetFullState() -> [String: Any]? {
        AppServices.shared.audio.pauseAndGetFullState().map(encodeFullState)
    }

    // MARK: - Remote Playback Projection

    static func updateRemotePlaybackProjection(
        snapshot: [String: Any],
        targetDeviceId: String,
        expectedGeneration: Int
    ) -> Bool {
        let songId = snapshot["songId"] as? String ?? ""
        let song = AppServices.shared.audio.resolveSongs(ids: [songId]).first
        let metadata = song.map {
            AudioMetadata(
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: Double($0.duration),
                coverArtId: $0.coverArt ?? $0.albumId
            )
        } ?? AudioMetadata(title: songId.isEmpty ? "Remote playback" : songId)
        AppServices.shared.audio.updateRemotePlaybackState(
            AudioRemotePlaybackProjection(
                metadata: metadata,
                isPlaying: snapshot["isPlaying"] as? Bool ?? false,
                position: number(snapshot["progressSeconds"]) ?? 0,
                duration: number(snapshot["durationSeconds"]) ?? metadata.duration ?? 0,
                isShuffleActive: snapshot["shuffle"] as? Bool ?? false,
                repeatMode: AudioRepeatMode(rawValue: snapshot["repeat"] as? String ?? "off") ?? .off,
                volume: number(snapshot["volume"]),
                targetDeviceId: targetDeviceId,
                expectedGeneration: expectedGeneration
            )
        )
        return true
    }

    static func clearRemotePlaybackProjection() -> Bool {
        AppServices.shared.audio.clearRemotePlaybackState()
        return true
    }

    // MARK: - Handoff

    static func prepareHandoffPlayback(
        snapshot: [String: Any],
        autoplay: Bool,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let handoff = AudioPayloadCodec.decodeHandoffSnapshot(snapshot) else {
            return false
        }
        AppServices.shared.audio.prepareHandoff(handoff, autoplay: autoplay, completion: completion)
        return true
    }

    static func rollbackHandoffPlayback() {
        AppServices.shared.audio.rollbackHandoff()
    }

    // MARK: - Private Helpers

    private static func encodeFullState(_ snapshot: AudioQueueSnapshot) -> [String: Any] {
        var result = AudioPayloadCodec.encodeQueueSnapshot(snapshot)
        result["requestId"] = nil // No requestId for internal calls
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Float: return Double(value)
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }
}
