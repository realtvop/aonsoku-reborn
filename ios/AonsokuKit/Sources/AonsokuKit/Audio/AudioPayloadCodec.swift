import Foundation

/// Stateless codecs for encoding/decoding audio-related payloads between native and coordination layers.
public enum AudioPayloadCodec {
    // MARK: - Source Codec

    public static func decodeSource(_ object: [String: Any]?) -> AudioSource? {
        guard let object, let kind = object["kind"] as? String else { return nil }
        let songId = object["songId"] as? String
        switch kind {
        case "stream":
            guard let url = object["url"] as? String else { return nil }
            return .stream(url: url, songId: songId)
        case "blob":
            guard let url = object["url"] as? String else { return nil }
            return .blob(url: url, songId: songId)
        case "native-file":
            guard let uri = object["uri"] as? String else { return nil }
            return .nativeFile(uri: uri, songId: songId)
        case "radio":
            guard let url = object["url"] as? String else { return nil }
            return .radio(url: url, radioId: object["radioId"] as? String)
        default: return nil
        }
    }

    // MARK: - Metadata Codec

    public static func decodeMetadata(_ object: [String: Any]?) -> AudioMetadata {
        AudioMetadata(
            title: object?["title"] as? String,
            artist: object?["artist"] as? String,
            album: object?["album"] as? String,
            duration: number(object?["duration"]),
            artworkUrl: object?["artworkUrl"] as? String,
            coverArtId: object?["coverArtId"] as? String
        )
    }

    // MARK: - Command Codec

    public static func decodeRemoteControlCommand(_ object: [String: Any]) -> AudioCommand? {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "play": return .play
        case "pause": return .pause
        case "toggle_play_pause": return .togglePlayPause
        case "stop": return .stop
        case "previous": return .previous
        case "next": return .next
        case "seek":
            guard let seconds = finiteNumber(object["seconds"]), seconds >= 0 else {
                return nil
            }
            return .seek(seconds)
        case "set_shuffle":
            guard let enabled = object["enabled"] as? Bool else { return nil }
            return .setShuffle(enabled)
        case "set_repeat":
            guard let rawMode = object["mode"] as? String,
                  let mode = AudioRepeatMode(rawValue: rawMode) else {
                return nil
            }
            return .setRepeat(mode)
        case "set_volume":
            guard let volume = finiteNumber(object["volume"]),
                  (0 ... 1).contains(volume) else {
                return nil
            }
            return .setVolume(volume)
        case "play_song":
            guard let id = nonEmptyString(object["song_id"]) else { return nil }
            return .playSong(id)
        case "play_album":
            guard let id = nonEmptyString(object["album_id"]),
                  let index = optionalInteger(object, key: "index"),
                  let shuffle = optionalBoolean(object, key: "shuffle") else {
                return nil
            }
            return .playAlbum(
                id: id,
                index: index ?? 0,
                shuffle: shuffle ?? false
            )
        case "play_playlist":
            guard let id = nonEmptyString(object["playlist_id"]),
                  let index = optionalInteger(object, key: "index"),
                  let shuffle = optionalBoolean(object, key: "shuffle") else {
                return nil
            }
            return .playPlaylist(
                id: id,
                index: index ?? 0,
                shuffle: shuffle ?? false
            )
        case "play_at_index":
            guard let songIds = songIds(object["song_ids"]),
                  let index = integer(object["index"]),
                  songIds.indices.contains(index) else {
                return nil
            }
            return .playAtIndex(
                songIds: songIds,
                index: index
            )
        case "add_to_queue_next", "add_to_queue_last":
            guard let songIds = songIds(object["song_ids"]) else { return nil }
            return .addToQueue(
                songIds: songIds,
                position: type == "add_to_queue_next" ? "next" : "last"
            )
        case "remove_from_queue":
            guard let songIds = songIds(object["song_ids"]) else { return nil }
            return .removeFromQueue(songIds: songIds)
        case "reorder_queue":
            guard let from = integer(object["from"]),
                  let to = integer(object["to"]) else {
                return nil
            }
            return .reorderQueue(
                from: from,
                to: to
            )
        case "clear_queue": return .clearQueue
        case "toggle_like": return .toggleLike
        default: return nil
        }
    }

    public static func isSupportedRemoteControlCommand(_ type: String) -> Bool {
        [
            "play", "pause", "toggle_play_pause", "stop", "previous", "next",
            "seek", "set_shuffle", "set_repeat", "set_volume", "play_song",
            "play_album", "play_playlist", "play_at_index", "toggle_like",
            "add_to_queue_next", "add_to_queue_last", "remove_from_queue",
            "reorder_queue", "clear_queue",
        ].contains(type)
    }

    // MARK: - Handoff Snapshot Codec

    public static func decodeHandoffSnapshot(_ object: [String: Any]) -> AudioHandoffSnapshot? {
        guard let songId = object["songId"] as? String, !songId.isEmpty else {
            return nil
        }
        var contextQueue = object["contextQueue"] as? [String] ?? []
        let userQueue = object["userQueue"] as? [String] ?? []
        let inUserQueue = object["inUserQueue"] as? Bool ?? false
        var contextIndex = object["contextIndex"] as? Int ?? 0
        if contextQueue.isEmpty, userQueue.isEmpty {
            contextQueue = [songId]
            contextIndex = 0
        }
        let sourceId: AudioQueueSource?
        if let raw = object["sourceId"] as? String,
           let separator = raw.firstIndex(of: ":") {
            sourceId = AudioQueueSource(
                type: String(raw[..<separator]),
                id: String(raw[raw.index(after: separator)...])
            )
        } else {
            sourceId = nil
        }
        return AudioHandoffSnapshot(
            songId: songId,
            progressSeconds: number(object["progressSeconds"]) ?? 0,
            contextQueue: contextQueue,
            contextIndex: contextIndex,
            userQueue: userQueue,
            inUserQueue: inUserQueue,
            restorePrevious: object["restorePrevious"] as? [String] ?? [],
            shuffle: object["shuffle"] as? Bool ?? false,
            repeatMode: AudioRepeatMode(rawValue: object["repeat"] as? String ?? "off") ?? .off,
            sourceId: sourceId,
            sourceName: object["sourceName"] as? String,
            volume: number(object["volume"])
        )
    }

    // MARK: - Queue Snapshot Codec

    public static func encodeQueueSnapshot(_ snapshot: AudioQueueSnapshot) -> [String: Any] {
        let source: Any = snapshot.sourceId.map {
            ["type": $0.type, "id": $0.id] as [String: Any]
        } ?? NSNull()
        return [
            "contextQueue": [
                "songs": snapshot.contextSongs.map(encodeSong),
                "currentIndex": snapshot.currentIndex,
                "sourceId": source,
                "sourceName": snapshot.sourceName ?? NSNull(),
            ],
            "userQueue": snapshot.userQueue.map(encodeSong),
            "originalContextSongs": snapshot.originalContextSongs.map(encodeSong),
            "originalUserSongs": snapshot.originalUserSongs.map(encodeSong),
            "shuffleHistory": snapshot.shuffleHistory,
            "shuffleStartHistory": snapshot.shuffleStartHistory,
            "playedUserQueueHistory": snapshot.playedUserQueueHistory.map(encodeSong),
            "isInUserQueue": snapshot.isInUserQueue,
            "isShuffleActive": snapshot.isShuffleActive,
            "loopState": snapshot.loopState.rawValue,
            "isPlaying": snapshot.isPlaying,
            "currentTime": snapshot.currentTime,
            "duration": snapshot.duration,
            "currentSongId": snapshot.currentSongId ?? NSNull(),
            "isRestored": snapshot.isRestored,
        ]
    }

    // MARK: - Cached File Codec

    public static func encodeCachedFile(_ file: CachedAudioFile) -> [String: Any] {
        var object: [String: Any] = ["songId": file.songId, "uri": file.uri]
        object["contentType"] = file.contentType
        object["sizeBytes"] = file.sizeBytes.map(NSNumber.init(value:))
        object["lastModifiedAt"] = file.lastModifiedAt
        return object
    }

    // MARK: - Private Helpers

    private static func encodeSong(_ song: QueueSong) -> [String: Any] {
        var object: [String: Any] = [
            "id": song.id, "title": song.title, "artist": song.artist,
            "album": song.album, "duration": song.duration,
            "streamUrl": song.streamUrl,
        ]
        object["artistId"] = song.artistId
        object["albumId"] = song.albumId
        object["coverArtId"] = song.coverArtId
        object["cachedFileUri"] = song.cachedFileUri
        return object
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

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard !(value is Bool), let result = number(value), result.isFinite else {
            return nil
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        let maxSafeJSONInteger = 9_007_199_254_740_991.0
        guard let value = finiteNumber(value),
              value >= 0,
              value <= maxSafeJSONInteger,
              value.rounded(.towardZero) == value else {
            return nil
        }
        return Int(value)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func songIds(_ value: Any?) -> [String]? {
        guard let values = value as? [Any], values.count <= 2_000 else {
            return nil
        }
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let id = nonEmptyString(value) else { return nil }
            result.append(id)
        }
        return result
    }

    /// Returns an outer optional so a present-but-invalid value can be
    /// distinguished from an omitted optional field.
    private static func optionalInteger(
        _ object: [String: Any],
        key: String
    ) -> Int?? {
        guard let value = object[key], !(value is NSNull) else { return .some(nil) }
        guard let value = integer(value) else { return nil }
        return .some(value)
    }

    private static func optionalBoolean(
        _ object: [String: Any],
        key: String
    ) -> Bool?? {
        guard let value = object[key], !(value is NSNull) else { return .some(nil) }
        guard let value = value as? Bool else { return nil }
        return .some(value)
    }
}
