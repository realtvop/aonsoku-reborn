import Capacitor
import Foundation

@objc(AonsokuNativeAudioPlugin)
public final class AonsokuNativeAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AonsokuNativeAudioPlugin"
    public let jsName = "AonsokuNativeAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setRepeatMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setShuffle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "markAsShuffled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "skipToNext", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "skipToPrevious", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateMetadata", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateRemotePlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearRemotePlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "preload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clear", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "storeAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAudioFileSize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearAudioFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setContextQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "addToUserQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeFromUserQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearUserQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateContextQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reorderContextQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "playAtIndex", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getFullState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resolveSongs", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadAudioFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelDownload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getScrobbleBuffer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearScrobbleBuffer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSystemVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSystemVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolumeHUDEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLikeActive", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSleepTimer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelSleepTimer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSleepTimerRemaining", returnType: CAPPluginReturnPromise),
    ]

    private let service = AppServices.shared.audio
    private var eventToken: UUID?

    public override func load() {
        super.load()
        eventToken = service.subscribe { [weak self] event in
            DispatchQueue.main.async { self?.forward(event) }
        }
        service.start(volumeHostView: bridge?.viewController?.view)
    }

    deinit {
        if let eventToken { service.unsubscribe(eventToken) }
    }

    @objc func load(_ call: CAPPluginCall) {
        guard let source = Self.source(from: call.getObject("source")) else {
            call.reject("Missing or invalid native audio source.", "invalid_source")
            return
        }
        let request = AudioLoadRequest(
            source: source,
            metadata: Self.metadata(from: call.getObject("metadata")),
            autoplay: call.getBool("autoplay") ?? false,
            startTime: call.getDouble("startTime") ?? 0,
            requestId: call.getString("requestId")
        )
        service.load(request) { result in Self.resolve(call, result: result) }
    }

    @objc func play(_ call: CAPPluginCall) {
        service.play { result in Self.resolve(call, result: result) }
    }

    @objc func pause(_ call: CAPPluginCall) { service.pause(); call.resolve() }
    @objc func stop(_ call: CAPPluginCall) { service.stop(); call.resolve() }

    @objc func seek(_ call: CAPPluginCall) {
        service.seek(to: call.getDouble("position") ?? 0) { call.resolve() }
    }

    @objc func setRepeatMode(_ call: CAPPluginCall) {
        service.setRepeatMode(
            AudioRepeatMode(rawValue: call.getString("mode") ?? "off") ?? .off
        )
        call.resolve()
    }

    @objc func setShuffle(_ call: CAPPluginCall) {
        service.setShuffle(call.getBool("enabled") ?? false)
        call.resolve()
    }

    @objc func markAsShuffled(_ call: CAPPluginCall) {
        service.markAsShuffled(
            originalSongs: Self.songs(from: call.getArray("originalSongs"))
        )
        call.resolve()
    }

    @objc func setQueue(_ call: CAPPluginCall) {
        let items = (call.getArray("items") ?? []).compactMap { value
            -> (AudioSource, AudioMetadata)? in
            guard let item = value as? JSObject,
                  let source = Self.source(from: item["source"] as? JSObject)
            else { return nil }
            return (source, Self.metadata(from: item["metadata"] as? JSObject))
        }
        let index = call.getInt("index") ?? 0
        guard index >= 0, items.isEmpty ? index == 0 : index < items.count else {
            call.reject("Queue index is outside the native queue.", "invalid_queue")
            return
        }
        service.setQueue(items: items, index: index)
        call.resolve()
    }

    @objc func skipToNext(_ call: CAPPluginCall) { service.skipToNext(); call.resolve() }
    @objc func skipToPrevious(_ call: CAPPluginCall) { service.skipToPrevious(); call.resolve() }

    @objc func updateMetadata(_ call: CAPPluginCall) {
        service.updateMetadata(AudioMetadata(
            title: call.getString("title"),
            artist: call.getString("artist"),
            album: call.getString("album"),
            duration: call.getDouble("duration"),
            artworkUrl: call.getString("artworkUrl"),
            coverArtId: call.getString("coverArtId")
        ))
        call.resolve()
    }

    @objc func updateRemotePlaybackState(_ call: CAPPluginCall) {
        let metadata = Self.metadata(from: call.getObject("metadata"))
        service.updateRemotePlaybackState(AudioRemotePlaybackProjection(
            metadata: metadata,
            isPlaying: call.getBool("isPlaying") ?? false,
            position: max(0, Self.number(call.getValue("position")) ?? 0),
            duration: max(0, Self.number(call.getValue("duration")) ?? metadata.duration ?? 0),
            isShuffleActive: call.getBool("isShuffleActive") ?? false,
            repeatMode: AudioRepeatMode(rawValue: call.getString("repeatMode") ?? "off") ?? .off,
            volume: Self.number(call.getValue("volume")),
            targetDeviceId: call.getString("targetDeviceId"),
            expectedGeneration: call.getInt("expectedGeneration")
        ))
        call.resolve()
    }

    @objc func clearRemotePlaybackState(_ call: CAPPluginCall) {
        service.clearRemotePlaybackState(); call.resolve()
    }

    @objc func preload(_ call: CAPPluginCall) { call.resolve() }
    @objc func clear(_ call: CAPPluginCall) { service.clear(); call.resolve() }

    @objc func storeAudioFile(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId"), !songId.isEmpty,
              let encoded = call.getString("dataBase64"),
              let data = Data(base64Encoded: encoded) else {
            call.reject("Missing native cache data.", "invalid_cache_request")
            return
        }
        let contentType = call.getString("contentType") ?? "audio/mpeg"
        DispatchQueue.global(qos: .utility).async { [service] in
            do {
                let file = try service.storeAudioFile(songId: songId, data: data, contentType: contentType)
                call.resolve(Self.object(from: file))
            } catch {
                call.reject(error.localizedDescription, "cache_failure", error)
            }
        }
    }

    @objc func resolveAudioFile(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            call.reject("Missing songId.", "invalid_cache_request"); return
        }
        DispatchQueue.global(qos: .utility).async { [service] in
            do {
                let file = try service.resolveAudioFile(songId: songId)
                call.resolve(["file": file.map(Self.object(from:)) ?? NSNull()])
            } catch {
                call.reject(error.localizedDescription, "cache_failure", error)
            }
        }
    }

    @objc func getAudioFileSize(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            call.reject("Missing songId.", "invalid_cache_request"); return
        }
        DispatchQueue.global(qos: .utility).async { [service] in
            do {
                let size = try service.resolveAudioFile(songId: songId)?.sizeBytes
                call.resolve(["sizeBytes": size.map(NSNumber.init(value:)) ?? NSNull()])
            } catch {
                call.reject(error.localizedDescription, "cache_failure", error)
            }
        }
    }

    @objc func deleteAudioFile(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            call.reject("Missing songId.", "invalid_cache_request"); return
        }
        DispatchQueue.global(qos: .utility).async { [service] in
            do { call.resolve(["deleted": try service.deleteAudioFile(songId: songId)]) }
            catch { call.reject(error.localizedDescription, "cache_failure", error) }
        }
    }

    @objc func clearAudioFiles(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .utility).async { [service] in
            do { call.resolve(["deletedCount": try service.clearAudioFiles()]) }
            catch { call.reject(error.localizedDescription, "cache_failure", error) }
        }
    }

    @objc func setContextQueue(_ call: CAPPluginCall) {
        let songs = Self.songs(from: call.getArray("songs"))
        guard !songs.isEmpty else {
            call.reject("Context queue must contain songs.", "invalid_queue"); return
        }
        var sourceId: AudioQueueSource?
        if let source = call.getObject("sourceId"),
           let type = source["type"] as? String,
           let id = source["id"] as? String {
            sourceId = AudioQueueSource(type: type, id: id)
        }
        service.setContextQueue(
            songs: songs,
            currentIndex: call.getInt("currentIndex") ?? 0,
            sourceId: sourceId,
            sourceName: call.getString("sourceName"),
            autoplay: call.getBool("autoplay") ?? true,
            startTime: call.getDouble("startTime"),
            repeatMode: call.getString("repeatMode").flatMap(AudioRepeatMode.init)
        )
        call.resolve()
    }

    @objc func addToUserQueue(_ call: CAPPluginCall) {
        service.addToUserQueue(
            songs: Self.songs(from: call.getArray("songs")),
            position: call.getString("position") ?? "last"
        )
        call.resolve()
    }

    @objc func removeFromUserQueue(_ call: CAPPluginCall) {
        service.removeFromUserQueue(indices: call.getArray("indices") as? [Int] ?? [])
        call.resolve()
    }

    @objc func clearUserQueue(_ call: CAPPluginCall) { service.clearUserQueue(); call.resolve() }

    @objc func updateContextQueue(_ call: CAPPluginCall) {
        service.updateContextQueue(
            songs: Self.songs(from: call.getArray("songs")),
            currentIndex: call.getInt("currentIndex") ?? 0
        )
        call.resolve()
    }

    @objc func reorderContextQueue(_ call: CAPPluginCall) {
        service.reorderContextQueue(
            from: call.getInt("fromIndex") ?? 0,
            to: call.getInt("toIndex") ?? 0
        )
        call.resolve()
    }

    @objc func playAtIndex(_ call: CAPPluginCall) {
        service.playAtIndex(call.getInt("index") ?? 0, startTime: call.getDouble("startTime"))
        call.resolve()
    }

    @objc func getFullState(_ call: CAPPluginCall) {
        call.resolve(service.fullState().map(Self.object(from:)) ?? [:])
    }

    @objc func resolveSongs(_ call: CAPPluginCall) {
        let ids = call.getArray("ids") as? [String] ?? []
        DispatchQueue.global(qos: .userInitiated).async { [service] in
            call.resolve([
                "songs": service.resolveSongs(ids: ids).map {
                    $0.toDictionary().compactMapValues { $0 }
                },
            ])
        }
    }

    @objc func getScrobbleBuffer(_ call: CAPPluginCall) {
        let entries = service.scrobbleEntries().map { entry in
            [
                "songId": entry.songId,
                "playedDurationMs": entry.playedDurationMs,
                "timestamp": entry.timestamp,
            ] as JSObject
        }
        call.resolve(["entries": entries])
    }

    @objc func clearScrobbleBuffer(_ call: CAPPluginCall) {
        service.clearScrobbleEntries(); call.resolve()
    }

    @objc func downloadAudioFile(_ call: CAPPluginCall) {
        guard let songId = call.getString("songId"), !songId.isEmpty else {
            call.reject("Missing songId.", "invalid_download_request"); return
        }
        service.downloadAudioFile(
            songId: songId,
            maxBitRate: call.getInt("maxBitRate"),
            format: call.getString("format")
        )
        call.resolve()
    }

    @objc func cancelDownload(_ call: CAPPluginCall) {
        service.cancelDownload(songId: call.getString("songId")); call.resolve()
    }

    @objc func setSystemVolume(_ call: CAPPluginCall) {
        service.setSystemVolume(Double(call.getFloat("value") ?? 0.5)) { result in
            switch result {
            case .success(let volume): call.resolve(["volume": volume])
            case .failure(let error): call.reject(error.message, error.code)
            }
        }
    }

    @objc func getSystemVolume(_ call: CAPPluginCall) {
        call.resolve(["volume": service.systemVolume])
    }

    @objc func setVolumeHUDEnabled(_ call: CAPPluginCall) {
        service.setVolumeHUDEnabled(call.getBool("enabled") ?? true); call.resolve()
    }

    @objc func setLikeActive(_ call: CAPPluginCall) {
        service.setLikeActive(call.getBool("active") ?? false); call.resolve()
    }

    @objc func setSleepTimer(_ call: CAPPluginCall) {
        service.setSleepTimer(
            seconds: call.getDouble("seconds") ?? 0,
            mode: call.getString("mode") ?? "duration"
        )
        call.resolve()
    }

    @objc func cancelSleepTimer(_ call: CAPPluginCall) {
        service.cancelSleepTimer(); call.resolve()
    }

    @objc func getSleepTimerRemaining(_ call: CAPPluginCall) {
        call.resolve(["remainingSeconds": service.sleepTimerRemaining])
    }

    private func forward(_ event: AudioServiceEvent) {
        let name: String
        let data: JSObject
        switch event {
        case .playbackStateChanged(let state, let requestId):
            name = "playbackStateChanged"
            data = Self.withRequestId(["state": state.rawValue], requestId)
        case .progress(let currentTime, let duration, let buffered, let requestId):
            name = "progress"
            data = Self.withRequestId([
                "currentTime": currentTime,
                "duration": duration,
                "bufferedTime": buffered,
            ], requestId)
        case .durationChanged(let duration, let requestId):
            name = "durationChanged"
            data = Self.withRequestId(["duration": duration], requestId)
        case .bufferingChanged(let buffering, let requestId):
            name = "bufferingChanged"
            data = Self.withRequestId(["isBuffering": buffering], requestId)
        case .ended(let reason, let requestId):
            name = "ended"; data = Self.withRequestId(["reason": reason], requestId)
        case .error(let code, let message, let requestId):
            name = "error"
            data = Self.withRequestId(["code": code, "message": message], requestId)
        case .remoteCommand(let command, let position):
            name = "remoteCommand"
            var object: JSObject = ["command": command]
            if let position { object["position"] = position }
            data = object
        case .interruptionChanged(let type, let shouldResume):
            name = "interruptionChanged"
            var object: JSObject = ["type": type]
            if let shouldResume { object["shouldResume"] = shouldResume }
            data = object
        case .routeChanged(let reason):
            name = "routeChanged"; data = ["reason": reason]
        case .queueStateChanged(let index, let songId, let reason, let inUserQueue):
            name = "queueStateChanged"
            data = [
                "currentIndex": index, "songId": songId, "reason": reason,
                "isInUserQueue": inUserQueue,
            ]
        case .queueContentsChanged(let reason):
            name = "queueContentsChanged"; data = ["reason": reason]
        case .downloadProgress(let songId, let loaded, let total):
            name = "downloadProgress"
            data = [
                "songId": songId,
                "loaded": NSNumber(value: loaded),
                "total": NSNumber(value: total),
            ]
        case .downloadCompleted(let songId, let file):
            name = "downloadCompleted"
            data = Self.object(from: file).merging(["songId": songId]) { current, _ in current }
        case .downloadFailed(let songId, let message):
            name = "downloadFailed"; data = ["songId": songId, "error": message]
        case .streamCacheCompleted(let songId, let file):
            name = "streamCacheCompleted"
            data = Self.object(from: file).merging(["songId": songId]) { current, _ in current }
        case .bufferComplete(let songId, let requestId):
            name = "bufferComplete"; data = Self.withRequestId(["songId": songId], requestId)
        case .systemVolumeChanged(let volume):
            name = "systemVolumeChanged"; data = ["volume": volume]
        case .recoveryAttempt(let level, let attempt, let maxAttempts):
            name = "recoveryAttempt"
            data = ["level": level, "attempt": attempt, "maxAttempts": maxAttempts]
        case .sleepTimerFired(let reason):
            name = "sleepTimerFired"; data = ["reason": reason]
        }
        notifyListeners(name, data: data)
    }
}

extension AonsokuNativeAudioPlugin {
    internal static func executeRemoteControlCommandFromActive(
        _ object: [String: Any]
    ) -> Bool {
        guard let command = command(from: object) else { return false }
        return AppServices.shared.audio.execute(command)
    }

    internal static func getFullStateFromActive() -> [String: Any]? {
        AppServices.shared.audio.fullState().map(object(from:))
    }

    internal static func pauseAndGetFullStateFromActive() -> [String: Any]? {
        AppServices.shared.audio.pauseAndGetFullState().map(object(from:))
    }

    internal static func updateRemotePlaybackProjectionFromActive(
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

    internal static func clearRemotePlaybackProjectionFromActive() -> Bool {
        AppServices.shared.audio.clearRemotePlaybackState(); return true
    }

    internal static func prepareHandoffPlaybackFromActive(
        snapshot: [String: Any],
        autoplay: Bool,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let handoff = handoffSnapshot(from: snapshot) else { return false }
        AppServices.shared.audio.prepareHandoff(handoff, autoplay: autoplay, completion: completion)
        return true
    }

    internal static func rollbackHandoffPlaybackFromActive() {
        AppServices.shared.audio.rollbackHandoff()
    }

    internal static func decodeHandoffSnapshot(
        _ object: [String: Any]
    ) -> AudioHandoffSnapshot? {
        handoffSnapshot(from: object)
    }

    internal static func decodeSource(_ object: JSObject?) -> AudioSource? {
        source(from: object)
    }

    internal static func decodeMetadata(_ object: JSObject?) -> AudioMetadata {
        metadata(from: object)
    }

    internal static func decodeRemoteControlCommand(
        _ object: [String: Any]
    ) -> AudioCommand? {
        command(from: object)
    }

    internal static func isSupportedRemoteControlCommand(_ type: String) -> Bool {
        command(from: ["type": type]) != nil || [
            "play_song", "play_album", "play_playlist", "play_at_index",
            "add_to_queue_next", "add_to_queue_last", "remove_from_queue",
            "reorder_queue",
        ].contains(type)
    }
}

private extension AonsokuNativeAudioPlugin {
    static func resolve(
        _ call: CAPPluginCall,
        result: Result<Void, AudioServiceError>
    ) {
        switch result {
        case .success: call.resolve()
        case .failure(let error): call.reject(error.message, error.code)
        }
    }

    static func source(from object: JSObject?) -> AudioSource? {
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

    static func metadata(from object: JSObject?) -> AudioMetadata {
        AudioMetadata(
            title: object?["title"] as? String,
            artist: object?["artist"] as? String,
            album: object?["album"] as? String,
            duration: number(object?["duration"]),
            artworkUrl: object?["artworkUrl"] as? String,
            coverArtId: object?["coverArtId"] as? String
        )
    }

    static func songs(from values: [Any]?) -> [QueueSong] {
        (values ?? []).compactMap { value in
            guard let object = value as? [String: Any],
                  let id = object["id"] as? String else { return nil }
            return QueueSong(
                id: id,
                title: object["title"] as? String ?? "",
                artist: object["artist"] as? String ?? "",
                artistId: object["artistId"] as? String,
                album: object["album"] as? String ?? "",
                albumId: object["albumId"] as? String,
                duration: number(object["duration"]) ?? 0,
                coverArtId: object["coverArtId"] as? String,
                streamUrl: object["streamUrl"] as? String ?? "",
                cachedFileUri: object["cachedFileUri"] as? String
            )
        }
    }

    static func object(from song: QueueSong) -> JSObject {
        var object: JSObject = [
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

    static func object(from snapshot: AudioQueueSnapshot) -> JSObject {
        let source: any JSValue = snapshot.sourceId.map {
            ["type": $0.type, "id": $0.id] as JSObject
        } ?? NSNull()
        return [
            "contextQueue": [
                "songs": snapshot.contextSongs.map(object(from:)),
                "currentIndex": snapshot.currentIndex,
                "sourceId": source,
                "sourceName": snapshot.sourceName ?? NSNull(),
            ],
            "userQueue": snapshot.userQueue.map(object(from:)),
            "originalContextSongs": snapshot.originalContextSongs.map(object(from:)),
            "originalUserSongs": snapshot.originalUserSongs.map(object(from:)),
            "shuffleHistory": snapshot.shuffleHistory,
            "shuffleStartHistory": snapshot.shuffleStartHistory,
            "playedUserQueueHistory": snapshot.playedUserQueueHistory.map(object(from:)),
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

    static func object(from file: CachedAudioFile) -> JSObject {
        var object: JSObject = ["songId": file.songId, "uri": file.uri]
        object["contentType"] = file.contentType
        object["sizeBytes"] = file.sizeBytes.map(NSNumber.init(value:))
        object["lastModifiedAt"] = file.lastModifiedAt
        return object
    }

    static func command(from object: [String: Any]) -> AudioCommand? {
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "play": return .play
        case "pause": return .pause
        case "toggle_play_pause": return .togglePlayPause
        case "stop": return .stop
        case "previous": return .previous
        case "next": return .next
        case "seek": return .seek(number(object["seconds"]) ?? 0)
        case "set_shuffle": return .setShuffle(object["enabled"] as? Bool ?? false)
        case "set_repeat":
            return .setRepeat(AudioRepeatMode(rawValue: object["mode"] as? String ?? "off") ?? .off)
        case "set_volume": return .setVolume(number(object["volume"]) ?? 0.5)
        case "play_song":
            guard let id = object["song_id"] as? String else { return nil }
            return .playSong(id)
        case "play_album":
            guard let id = object["album_id"] as? String else { return nil }
            return .playAlbum(
                id: id,
                index: object["index"] as? Int ?? 0,
                shuffle: object["shuffle"] as? Bool ?? false
            )
        case "play_playlist":
            guard let id = object["playlist_id"] as? String else { return nil }
            return .playPlaylist(
                id: id,
                index: object["index"] as? Int ?? 0,
                shuffle: object["shuffle"] as? Bool ?? false
            )
        case "play_at_index":
            return .playAtIndex(
                songIds: object["song_ids"] as? [String] ?? [],
                index: object["index"] as? Int ?? 0
            )
        case "add_to_queue_next", "add_to_queue_last":
            return .addToQueue(
                songIds: object["song_ids"] as? [String] ?? [],
                position: type == "add_to_queue_next" ? "next" : "last"
            )
        case "remove_from_queue":
            return .removeFromQueue(songIds: object["song_ids"] as? [String] ?? [])
        case "reorder_queue":
            return .reorderQueue(
                from: object["from"] as? Int ?? -1,
                to: object["to"] as? Int ?? -1
            )
        case "clear_queue": return .clearQueue
        case "toggle_like": return .toggleLike
        default: return nil
        }
    }

    static func handoffSnapshot(from object: [String: Any]) -> AudioHandoffSnapshot? {
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

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value
        case let value as Float: return Double(value)
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    static func withRequestId(_ data: JSObject, _ requestId: String?) -> JSObject {
        var data = data
        if let requestId { data["requestId"] = requestId }
        return data
    }
}
