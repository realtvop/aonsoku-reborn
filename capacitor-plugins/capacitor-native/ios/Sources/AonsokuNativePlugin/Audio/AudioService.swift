import AVFoundation
import Foundation
import MediaPlayer
import UIKit

public final class AudioService: NSObject, @unchecked Sendable {
    public typealias EventHandler = @Sendable (AudioServiceEvent) -> Void
    typealias PlayerFactory = (AVPlayerItem) -> AVPlayer

    private let audioSession = AVAudioSession.sharedInstance()
    private let queueEngine: NativeQueueEngine
    private let sourceResolver: NativeSourceResolver
    private let downloadManager: NativeDownloadManager
    private let scrobbleBuffer: NativeScrobbleBuffer
    private let scrobbleSubmitter: NativeScrobbleSubmitter
    private let recoveryController: PlaybackRecoveryController
    private let playerFactory: PlayerFactory
    private let stateQueue = DispatchQueue(
        label: "com.aonsoku.AudioService.state",
        qos: .userInitiated
    )
    private let listenerQueue = DispatchQueue(
        label: "com.aonsoku.AudioService.listeners"
    )
    private let persistence: PlaybackStatePersistence

    private var listeners: [UUID: EventHandler] = [:]
    private var stateListeners: [UUID: @Sendable (AudioPlaybackSnapshot) -> Void] = [:]
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var likelyToKeepUpObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var volumeObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private weak var volumeHostView: UIView?
    private var metadata = AudioMetadata()
    private var playbackState: AudioPlaybackSnapshot.State = .idle
    private var currentRequestId: String?
    private var currentSource: AudioSource?
    private var currentSourceURL: URL?
    private var currentSourceKind: String?
    private var playbackGeneration = 0
    private var isRecoveryReload = false
    private var loadedDuration: Double?
    private var isQueueActive = false
    private var savedRestoreTime: Double?
    private var remoteProjection: AudioRemotePlaybackProjection?
    private var preparedHandoffBefore: (PlaybackPersistState, Bool)?
    private var handoffGeneration = 0
    private var backgroundCacheSongIds = Set<String>()
    private var backgroundCacheCompletedSongIds = Set<String>()
    private var sleepTimer: Timer?
    private var sleepTimerEndDate: Date?
    private var sleepTimerMode = "duration"
    private var started = false

    public override convenience init() {
        self.init(databaseManager: .shared)
    }

    init(
        databaseManager: DatabaseManager,
        queueEngine: NativeQueueEngine = NativeQueueEngine(),
        sourceResolver: NativeSourceResolver = NativeSourceResolver(),
        downloadManager: NativeDownloadManager = NativeDownloadManager(),
        scrobbleBuffer: NativeScrobbleBuffer = NativeScrobbleBuffer(),
        scrobbleSubmitter: NativeScrobbleSubmitter = NativeScrobbleSubmitter(),
        recoveryController: PlaybackRecoveryController = PlaybackRecoveryController(),
        playerFactory: @escaping PlayerFactory = { AVPlayer(playerItem: $0) }
    ) {
        self.queueEngine = queueEngine
        self.sourceResolver = sourceResolver
        self.downloadManager = downloadManager
        self.scrobbleBuffer = scrobbleBuffer
        self.scrobbleSubmitter = scrobbleSubmitter
        self.recoveryController = recoveryController
        self.playerFactory = playerFactory
        self.persistence = PlaybackStatePersistence(
            repository: PlaybackStateRepository(db: databaseManager.dbPool)
        )
        super.init()
        queueEngine.delegate = self
        downloadManager.delegate = self
        recoveryController.delegate = self
    }

    deinit {
        teardown(deactivateSession: false)
    }

    public func start(volumeHostView: UIView? = nil) {
        dispatchMain { [weak self] in
            guard let self else { return }
            self.volumeHostView = volumeHostView ?? self.volumeHostView
            guard !self.started else { return }
            self.started = true
            do {
                try self.configureAudioSession()
            } catch {
                self.emitError(
                    code: "audio_session_failed",
                    message: error.localizedDescription
                )
            }
            self.restorePlaybackState()
            self.setupPersistence()
            self.registerAudioSessionObservers()
            self.registerRemoteCommands()
            self.observeSystemVolume()
            self.scrobbleSubmitter.submitPending(buffer: self.scrobbleBuffer)
        }
    }

    public func shutdown() {
        dispatchMain { [weak self] in
            self?.teardown(deactivateSession: true)
        }
    }

    private func teardown(deactivateSession: Bool) {
        started = false
        persistence.flushNow()
        persistence.stopProgressTracking()
        recoveryController.stopProgressMonitoring()
        unregisterRemoteCommands()
        removeAudioSessionObservers()
        volumeObservation?.invalidate()
        volumeObservation = nil
        sleepTimer?.invalidate()
        sleepTimer = nil
        clearPlayer(deactivateSession: deactivateSession)
    }

    public func applicationDidEnterBackground() {
        persistence.flushNow()
        recoveryController.setBackground(true)
    }

    public func applicationWillEnterForeground() {
        recoveryController.setBackground(false)
        start(volumeHostView: volumeHostView)
        dispatchMain { [weak self] in
            guard let self else { return }
            do {
                try self.configureAudioSession()
            } catch {
                self.emitError(
                    code: "audio_session_failed",
                    message: error.localizedDescription
                )
            }
            self.scrobbleSubmitter.submitPending(buffer: self.scrobbleBuffer)
        }
    }

    public func applicationWillTerminate() {
        persistence.flushNow(wait: true)
        shutdown()
    }

    @discardableResult
    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        downloadManager.handleEvents(
            forBackgroundSession: identifier,
            completionHandler: completionHandler
        )
    }

    @discardableResult
    public func subscribe(_ handler: @escaping EventHandler) -> UUID {
        let token = UUID()
        listenerQueue.sync { listeners[token] = handler }
        return token
    }

    public func unsubscribe(_ token: UUID) {
        listenerQueue.sync { listeners[token] = nil }
    }

    public func observeState(
        _ handler: @escaping @Sendable (AudioPlaybackSnapshot) -> Void
    ) -> AudioStateSubscription {
        let token = UUID()
        listenerQueue.sync { stateListeners[token] = handler }
        dispatchMain { [weak self] in
            guard let self else { return }
            handler(self.playbackSnapshot())
        }
        return AudioStateSubscription { [weak self] in
            self?.listenerQueue.sync {
                self?.stateListeners[token] = nil
            }
        }
    }

    public func stateUpdates() -> AsyncStream<AudioPlaybackSnapshot> {
        AsyncStream { continuation in
            let subscription = observeState { snapshot in
                continuation.yield(snapshot)
            }
            continuation.onTermination = { _ in subscription.cancel() }
        }
    }

    public func load(_ request: AudioLoadRequest, completion: @escaping (Result<Void, AudioServiceError>) -> Void) {
        dispatchMain { [weak self] in
            guard let self else { return }
            do {
                let resolved = try self.resolve(request.source)
                try self.configureAudioSession()
                if request.autoplay { try self.activateAudioSession() }

                self.isQueueActive = false
                self.currentRequestId = request.requestId
                self.currentSource = request.source
                self.currentSourceURL = resolved.url
                self.currentSourceKind = resolved.kind
                self.metadata = request.metadata
                self.loadedDuration = request.metadata.duration
                self.installPlayer(
                    url: resolved.url,
                    kind: self.currentSourceKind,
                    songId: Self.songId(request.source)
                )
                self.recoveryController.startProgressMonitoring(
                    generation: self.playbackGeneration,
                    sourceKind: self.recoverySourceKind()
                )
                self.emitPlaybackState(.loading, force: true)

                let startPlayback = {
                    if request.autoplay {
                        self.player?.play()
                        self.persistence.startProgressTracking()
                    }
                    completion(.success(()))
                }
                if request.startTime > 0 {
                    self.player?.seek(
                        to: self.makeTime(request.startTime),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { _ in startPlayback() }
                } else {
                    startPlayback()
                }
            } catch let error as AudioServiceError {
                self.emitError(code: error.code, message: error.message, requestId: request.requestId)
                completion(.failure(error))
            } catch {
                let serviceError = AudioServiceError(
                    code: "load_failed",
                    message: error.localizedDescription
                )
                self.emitError(code: serviceError.code, message: serviceError.message, requestId: request.requestId)
                completion(.failure(serviceError))
            }
        }
    }

    public func play(completion: ((Result<Void, AudioServiceError>) -> Void)? = nil) {
        dispatchMain { [weak self] in
            guard let self else { return }
            do {
                try self.activateAudioSession()
                if self.player == nil,
                   self.isQueueActive,
                   let song = self.queueEngine.currentSong {
                    let resume = self.savedRestoreTime
                    self.savedRestoreTime = nil
                    self.queueEngine.clearRestoredFlag()
                    self.loadQueueSong(song, autoplay: true, startTime: resume)
                } else if self.isAtEnd {
                    self.player?.seek(to: .zero) { _ in self.player?.play() }
                } else {
                    self.player?.play()
                }
                self.recoveryController.startProgressMonitoring(
                    generation: self.playbackGeneration,
                    sourceKind: self.recoverySourceKind()
                )
                self.persistence.startProgressTracking()
                completion?(.success(()))
            } catch {
                let serviceError = AudioServiceError(
                    code: "audio_session_failed",
                    message: error.localizedDescription
                )
                self.emitError(code: serviceError.code, message: serviceError.message)
                completion?(.failure(serviceError))
            }
        }
    }

    public func pause() {
        dispatchMain { [weak self] in
            self?.recoveryController.reportUserPause()
            self?.player?.pause()
            self?.scrobbleBuffer.pauseTracking()
            self?.persistence.flushNow()
            self?.emitPlaybackState(.paused)
        }
    }

    public func stop() {
        dispatchMain { [weak self] in
            guard let self else { return }
            self.player?.pause()
            self.recoveryController.reportUserPause()
            self.scrobbleBuffer.pauseTracking()
            self.player?.seek(to: .zero)
            self.persistence.flushNow()
            self.emitPlaybackState(.stopped, force: true)
            self.emit(.ended(reason: "stopped", requestId: self.currentRequestId))
        }
    }

    public func seek(to seconds: Double, completion: (() -> Void)? = nil) {
        dispatchMain { [weak self] in
            guard let self else { return }
            let position = max(0, seconds)
            self.recoveryController.reportUserSeek()
            self.player?.seek(
                to: self.makeTime(position),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                self.persistence.updateProgress(position)
                self.persistence.flushNow()
                self.emitProgress()
                self.updateNowPlayingPlaybackInfo()
                completion?()
            }
        }
    }

    public func setRepeatMode(_ mode: AudioRepeatMode) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.queueEngine.setLoopState(LoopState(rawValue: mode.rawValue) ?? .off)
            self.persistence.markStateDirty()
        }
    }

    public func setShuffle(_ enabled: Bool) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.queueEngine.setShuffleActive(enabled)
            self.persistence.markStateDirty()
        }
    }

    public func markAsShuffled(originalSongs: [QueueSong]) {
        stateQueue.async { [weak self] in
            self?.queueEngine.markAsShuffled(originalSongs: originalSongs)
            self?.persistence.markStateDirty()
        }
    }

    public func setQueue(items: [(AudioSource, AudioMetadata)], index: Int) {
        let songs = items.enumerated().map { itemIndex, item in
            Self.queueSong(
                source: item.0,
                metadata: item.1,
                fallbackId: "queue-\(itemIndex)"
            )
        }
        setContextQueue(songs: songs, currentIndex: index, autoplay: false)
    }

    public func setContextQueue(
        songs: [QueueSong],
        currentIndex: Int,
        sourceId: AudioQueueSource? = nil,
        sourceName: String? = nil,
        autoplay: Bool = true,
        startTime: Double? = nil,
        repeatMode: AudioRepeatMode? = nil
    ) {
        stateQueue.async { [weak self] in
            guard let self, !songs.isEmpty else { return }
            self.isQueueActive = true
            self.queueEngine.setContextQueue(
                songs: songs,
                currentIndex: currentIndex,
                autoplay: autoplay,
                startTime: startTime,
                sourceId: sourceId.map { QueueSourceId(type: $0.type, id: $0.id) },
                sourceName: sourceName
            )
            if let repeatMode {
                self.queueEngine.setLoopState(
                    LoopState(rawValue: repeatMode.rawValue) ?? .off
                )
            }
            self.persistence.markStateDirty()
        }
    }

    public func updateContextQueue(songs: [QueueSong], currentIndex: Int) {
        stateQueue.async { [weak self] in
            self?.queueEngine.updateContextQueue(
                songs: songs,
                currentIndex: currentIndex
            )
            self?.persistence.markStateDirty()
        }
    }

    public func reorderContextQueue(from: Int, to: Int) {
        stateQueue.async { [weak self] in
            self?.queueEngine.reorderContextQueue(fromIndex: from, toIndex: to)
            self?.persistence.markStateDirty()
        }
    }

    public func addToUserQueue(songs: [QueueSong], position: String) {
        stateQueue.async { [weak self] in
            self?.queueEngine.addToUserQueue(songs: songs, position: position)
            self?.persistence.markStateDirty()
        }
    }

    public func removeFromUserQueue(indices: [Int]) {
        stateQueue.async { [weak self] in
            self?.queueEngine.removeFromUserQueue(indices: indices)
            self?.persistence.markStateDirty()
        }
    }

    public func clearUserQueue() {
        stateQueue.async { [weak self] in
            self?.queueEngine.clearUserQueue()
            self?.persistence.markStateDirty()
        }
    }

    public func playAtIndex(_ index: Int, startTime: Double? = nil) {
        stateQueue.async { [weak self] in
            self?.queueEngine.playAtIndex(index, startTime: startTime)
        }
    }

    public func skipToNext() {
        stateQueue.async { [weak self] in self?.queueEngine.skipToNext() }
    }

    public func skipToPrevious() {
        let currentTime = player?.currentTime().seconds ?? 0
        stateQueue.async { [weak self] in
            self?.queueEngine.skipToPrevious(currentTime: currentTime)
        }
    }

    public func updateMetadata(_ metadata: AudioMetadata) {
        dispatchMain { [weak self] in
            self?.metadata = metadata
            self?.loadedDuration = metadata.duration
            self?.updateNowPlayingInfo()
        }
    }

    public func updateRemotePlaybackState(_ projection: AudioRemotePlaybackProjection) {
        dispatchMain { [weak self] in
            self?.remoteProjection = projection
            self?.updateNowPlayingInfo()
        }
    }

    public func clearRemotePlaybackState() {
        dispatchMain { [weak self] in
            self?.remoteProjection = nil
            self?.updateNowPlayingInfo()
        }
    }

    public func clear() {
        dispatchMain { [weak self] in
            guard let self else { return }
            self.clearPlayer(deactivateSession: true)
            try? self.persistence.repository.clear()
            self.playbackState = .idle
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            self.emitPlaybackState(.idle, force: true)
        }
    }

    public func fullState() -> AudioQueueSnapshot? {
        stateQueue.sync {
            guard isQueueActive else { return nil }
            return makeQueueSnapshot()
        }
    }

    public func playbackSnapshot() -> AudioPlaybackSnapshot {
        let queue = fullState()
        return AudioPlaybackSnapshot(
            state: playbackState,
            currentTime: currentTime,
            duration: duration,
            bufferedTime: bufferedTime,
            metadata: remoteProjection?.metadata ?? metadata,
            queue: queue
        )
    }

    public func pauseAndGetFullState() -> AudioQueueSnapshot? {
        dispatchMainSync {
            player?.pause()
            persistence.flushNow()
        }
        return fullState()
    }

    public func execute(_ command: AudioCommand) -> Bool {
        switch command {
        case .play:
            play()
        case .pause:
            pause()
        case .togglePlayPause:
            if player?.timeControlStatus == .playing { pause() } else { play() }
        case .stop:
            stop()
        case .previous:
            skipToPrevious()
        case .next:
            skipToNext()
        case .seek(let seconds):
            seek(to: seconds)
        case .setShuffle(let enabled):
            setShuffle(enabled)
        case .setRepeat(let mode):
            setRepeatMode(mode)
        case .setVolume(let value):
            setSystemVolume(value) { _ in }
        case .playSong(let id):
            playSongIds([id], index: 0)
        case .playAlbum(let id, let index, let shuffle):
            playAlbum(id: id, index: index, shuffle: shuffle)
        case .playPlaylist(let id, let index, let shuffle):
            playPlaylist(id: id, index: index, shuffle: shuffle)
        case .playAtIndex(let songIds, let index):
            playSongIds(songIds, index: index)
        case .addToQueue(let songIds, let position):
            addSongIds(songIds, position: position)
        case .removeFromQueue(let songIds):
            stateQueue.async { [weak self] in
                guard let self else { return }
                let ids = Set(songIds)
                let indices = self.queueEngine.userQueue.enumerated().compactMap {
                    ids.contains($0.element.id) ? $0.offset : nil
                }
                self.queueEngine.removeFromUserQueue(indices: indices)
            }
        case .reorderQueue(let from, let to):
            reorderContextQueue(from: from, to: to)
        case .clearQueue:
            clearUserQueue()
        case .toggleLike:
            toggleLike()
        }
        return true
    }

    public func prepareHandoff(
        _ snapshot: AudioHandoffSnapshot,
        autoplay: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let generation = stateQueue.sync { () -> Int in
            handoffGeneration += 1
            return handoffGeneration
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { completion(false); return }
            do {
                let ids = Self.orderedUnique(
                    snapshot.contextQueue + snapshot.userQueue +
                        snapshot.restorePrevious + [snapshot.songId]
                )
                let records = try SongRepository(
                    db: DatabaseManager.shared.dbPool
                ).getByIds(ids: ids)
                let byId = Dictionary(
                    uniqueKeysWithValues: records.map { ($0.id, $0.queueSong) }
                )
                guard ids.allSatisfy({ byId[$0] != nil }) else {
                    completion(false)
                    return
                }
                let context = snapshot.contextQueue.compactMap { byId[$0] }
                let user = snapshot.userQueue.compactMap { byId[$0] }
                let history = snapshot.restorePrevious.compactMap { byId[$0] }
                let current = snapshot.inUserQueue
                    ? user.first
                    : context[safe: snapshot.contextIndex]
                guard current?.id == snapshot.songId else {
                    completion(false)
                    return
                }
                self.stateQueue.async {
                    guard generation == self.handoffGeneration else {
                        completion(false)
                        return
                    }
                    if !autoplay, self.preparedHandoffBefore == nil {
                        self.preparedHandoffBefore = (
                            PlaybackPersistState(
                                from: self.queueEngine,
                                currentTime: self.currentTime
                            ),
                            self.player?.timeControlStatus == .playing
                        )
                    }
                    var state = PlaybackPersistState(
                        from: self.queueEngine,
                        currentTime: snapshot.progressSeconds
                    )
                    state.contextSongs = context
                    state.currentIndex = snapshot.contextIndex
                    state.userQueue = user
                    state.originalContextSongs = context
                    state.originalUserSongs = user
                    state.playedUserQueueHistory = history
                    state.isInUserQueue = snapshot.inUserQueue
                    state.isShuffleActive = snapshot.shuffle
                    state.loopState = snapshot.repeatMode.rawValue
                    state.sourceId = snapshot.sourceId.map {
                        QueueSourceId(type: $0.type, id: $0.id)
                    }
                    state.sourceName = snapshot.sourceName
                    self.queueEngine.restoreState(from: state)
                    self.isQueueActive = true
                    if let current {
                        self.loadQueueSong(
                            current,
                            autoplay: autoplay,
                            startTime: snapshot.progressSeconds
                        )
                    }
                    if autoplay, let volume = snapshot.volume {
                        self.setSystemVolume(volume) { _ in }
                    }
                    if autoplay { self.preparedHandoffBefore = nil }
                    self.persistence.markStateDirty()
                    completion(true)
                }
            } catch {
                NativeLogger.shared.warn(
                    "Failed to prepare handoff: \(error.localizedDescription)",
                    source: "AudioService"
                )
                completion(false)
            }
        }
    }

    public func rollbackHandoff() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.handoffGeneration += 1
            guard let (state, autoplay) = self.preparedHandoffBefore else { return }
            self.preparedHandoffBefore = nil
            self.queueEngine.restoreState(from: state)
            self.isQueueActive = true
            if let song = self.queueEngine.currentSong {
                self.loadQueueSong(
                    song,
                    autoplay: autoplay,
                    startTime: state.currentTime
                )
            }
        }
    }

    func resolveSongs(ids: [String]) -> [SongRecord] {
        (try? SongRepository(db: DatabaseManager.shared.dbPool).getByIds(ids: ids)) ?? []
    }

    func scrobbleEntries() -> [ScrobbleEntry] {
        scrobbleBuffer.getEntries()
    }

    public func clearScrobbleEntries() {
        scrobbleBuffer.clear()
    }

    public func downloadAudioFile(songId: String, maxBitRate: Int?, format: String?) {
        downloadManager.download(
            songId: songId,
            maxBitRate: maxBitRate,
            format: format
        )
    }

    public func cancelDownload(songId: String?) {
        if let songId { downloadManager.cancel(songId: songId) }
        else { downloadManager.cancelAll() }
    }

    public func storeAudioFile(
        songId: String,
        data: Data,
        contentType: String
    ) throws -> CachedAudioFile {
        let directory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let cacheId = AudioCacheUtils.cacheId(for: songId)
        let ext = AudioCacheUtils.fileExtension(for: contentType)
        let fileName = "\(cacheId).\(ext)"
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        let modified = Date().timeIntervalSince1970 * 1000
        let metadata = NativeCachedAudioFileMetadata(
            songId: songId,
            fileName: fileName,
            contentType: contentType,
            lastModifiedAt: modified
        )
        let metadataURL = directory.appendingPathComponent("\(cacheId).json")
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
        return cachedFile(
            songId: songId,
            fileURL: fileURL,
            contentType: contentType,
            lastModifiedAt: modified
        )
    }

    public func resolveAudioFile(songId: String) throws -> CachedAudioFile? {
        let directory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: false)
        let cacheId = AudioCacheUtils.cacheId(for: songId)
        let metadataURL = directory.appendingPathComponent("\(cacheId).json")
        guard let data = try? Data(contentsOf: metadataURL),
              let stored = try? JSONDecoder().decode(
                  NativeCachedAudioFileMetadata.self,
                  from: data
              ),
              stored.songId == songId else { return nil }
        let fileURL = directory.appendingPathComponent(stored.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return cachedFile(
            songId: songId,
            fileURL: fileURL,
            contentType: stored.contentType,
            lastModifiedAt: stored.lastModifiedAt
        )
    }

    public func deleteAudioFile(songId: String) throws -> Bool {
        guard let file = try resolveAudioFile(songId: songId),
              let fileURL = URL(string: file.uri) else { return false }
        let directory = fileURL.deletingLastPathComponent()
        let metadataURL = directory.appendingPathComponent(
            "\(AudioCacheUtils.cacheId(for: songId)).json"
        )
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: metadataURL)
        return true
    }

    public func clearAudioFiles() throws -> Int {
        let directory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let count = files.filter { $0.pathExtension.lowercased() != "json" }.count
        for file in files { try FileManager.default.removeItem(at: file) }
        return count
    }

    public func setSystemVolume(
        _ value: Double,
        completion: @escaping (Result<Float, AudioServiceError>) -> Void
    ) {
        dispatchMain { [weak self] in
            guard let self else { return }
            let clamped = Float(max(0, min(1, value)))
            let volumeView = self.volumeView ?? MPVolumeView(
                frame: CGRect(x: -2000, y: -2000, width: 120, height: 40)
            )
            if self.volumeView == nil {
                volumeView.alpha = 0.001
                self.volumeHostView?.addSubview(volumeView)
                self.volumeView = volumeView
            }
            volumeView.layoutIfNeeded()
            guard let slider = Self.findSlider(in: volumeView) else {
                completion(.failure(AudioServiceError(
                    code: "volume_control_unavailable",
                    message: "System volume control is unavailable."
                )))
                return
            }
            slider.value = clamped
            slider.sendActions(for: .valueChanged)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let actual = self.audioSession.outputVolume
                self.emit(.systemVolumeChanged(actual))
                completion(.success(actual))
            }
        }
    }

    public var systemVolume: Float { audioSession.outputVolume }

    public func setVolumeHUDEnabled(_ enabled: Bool) {
        dispatchMain { [weak self] in
            if enabled {
                self?.volumeView?.removeFromSuperview()
                self?.volumeView = nil
            } else if self?.volumeView == nil {
                let view = MPVolumeView(
                    frame: CGRect(x: -2000, y: -2000, width: 120, height: 40)
                )
                view.alpha = 0.001
                self?.volumeHostView?.addSubview(view)
                self?.volumeView = view
            }
        }
    }

    public func setLikeActive(_ active: Bool) {
        dispatchMain {
            MPRemoteCommandCenter.shared().likeCommand.isActive = active
        }
    }

    public func setSleepTimer(seconds: Double, mode: String) {
        dispatchMain { [weak self] in
            guard let self else { return }
            self.sleepTimer?.invalidate()
            self.sleepTimerMode = mode
            if mode == "endOfTrack" {
                self.sleepTimerEndDate = nil
                self.sleepTimer = nil
            } else {
                self.sleepTimerEndDate = Date().addingTimeInterval(seconds)
                self.sleepTimer = Timer.scheduledTimer(
                    withTimeInterval: seconds,
                    repeats: false
                ) { [weak self] _ in self?.fireSleepTimer(reason: "duration") }
            }
        }
    }

    public func cancelSleepTimer() {
        dispatchMain { [weak self] in
            self?.sleepTimer?.invalidate()
            self?.sleepTimer = nil
            self?.sleepTimerEndDate = nil
            self?.sleepTimerMode = "duration"
        }
    }

    public var sleepTimerRemaining: Double {
        sleepTimerEndDate.map { max(0, $0.timeIntervalSinceNow) } ?? 0
    }

    private func installPlayer(url: URL, kind: String?, songId: String?) {
        clearPlayer(deactivateSession: false)
        let generation = playbackGeneration
        currentSourceURL = url
        currentSourceKind = kind
        if kind == "stream", let songId { startBackgroundCache(songId: songId) }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = kind == "radio"
            ? 0
            : .greatestFiniteMagnitude
        let player = playerFactory(item)
        self.playerItem = item
        self.player = player
        observe(item: item, player: player, generation: generation)
        updateNowPlayingInfo()
    }

    private func observe(
        item: AVPlayerItem,
        player: AVPlayer,
        generation: Int
    ) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self, weak item] _, _ in
            guard let self,
                  let item,
                  item === self.playerItem,
                  generation == self.playbackGeneration else { return }
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self.emitDuration()
                    if player.timeControlStatus == .playing {
                        self.emitPlaybackState(.playing)
                    }
                case .failed:
                    self.recoveryController.triggerRecovery(
                        currentTime: player.currentTime(),
                        generation: generation,
                        sourceKind: self.recoverySourceKind()
                    )
                default:
                    break
                }
            }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self, weak player] _, _ in
            guard let self,
                  let player,
                  player === self.player,
                  generation == self.playbackGeneration else { return }
            DispatchQueue.main.async {
                switch player.timeControlStatus {
                case .playing:
                    self.recoveryController.reportPlaybackResumed(
                        generation: generation
                    )
                    self.scrobbleBuffer.resumeTracking()
                    self.emit(.bufferingChanged(false, requestId: self.currentRequestId))
                    self.emitPlaybackState(.playing)
                case .paused:
                    self.scrobbleBuffer.pauseTracking()
                    if self.playbackState != .ended && self.playbackState != .stopped {
                        self.emitPlaybackState(.paused)
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self.emit(.bufferingChanged(true, requestId: self.currentRequestId))
                    self.emitPlaybackState(.loading)
                @unknown default:
                    break
                }
            }
        }
        durationObservation = item.observe(\.duration, options: [.new]) {
            [weak self] _, _ in DispatchQueue.main.async { self?.emitDuration() }
        }
        bufferEmptyObservation = item.observe(
            \.isPlaybackBufferEmpty,
            options: [.new]
        ) { [weak self, weak item, weak player] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                guard let self,
                      let item,
                      let player,
                      item === self.playerItem,
                      player === self.player,
                      generation == self.playbackGeneration,
                      player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                else { return }
                self.recoveryController.triggerRecovery(
                    currentTime: player.currentTime(),
                    generation: generation,
                    sourceKind: self.recoverySourceKind()
                )
            }
        }
        likelyToKeepUpObservation = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.new]
        ) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                self?.recoveryController.reportLikelyToKeepUp(
                    generation: generation
                )
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard generation == self.playbackGeneration else { return }
            self.persistence.updateProgress(self.currentTime)
            if !item.isPlaybackBufferEmpty {
                self.recoveryController.reportProgress(
                    at: player.currentTime(),
                    generation: generation
                )
            }
            self.emitProgress()
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in self?.handleEnded() }
        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error
            guard let self, generation == self.playbackGeneration else { return }
            NativeLogger.shared.warn(
                "Playback ended with error: \(error?.localizedDescription ?? "unknown")",
                source: "AudioService"
            )
            self.recoveryController.triggerRecovery(
                currentTime: player.currentTime(),
                generation: generation,
                sourceKind: self.recoverySourceKind()
            )
        }
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let self,
                  let player,
                  generation == self.playbackGeneration else { return }
            if let songId = self.queueEngine.currentSong?.id,
               self.backgroundCacheCompletedSongIds.contains(songId),
               self.isAtEnd {
                self.backgroundCacheCompletedSongIds.remove(songId)
                self.handleEnded()
                return
            }
            self.recoveryController.triggerRecovery(
                currentTime: player.currentTime(),
                generation: generation,
                sourceKind: self.recoverySourceKind()
            )
        }
    }

    private func clearPlayer(deactivateSession: Bool) {
        playbackGeneration += 1
        removePlayerObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        persistence.stopProgressTracking()
        recoveryController.stopProgressMonitoring()
        recoveryController.reset()
        if deactivateSession { try? audioSession.setActive(false) }
    }

    private func removePlayerObservers() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        durationObservation?.invalidate()
        timeControlObservation?.invalidate()
        bufferEmptyObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        statusObservation = nil
        durationObservation = nil
        timeControlObservation = nil
        bufferEmptyObservation = nil
        likelyToKeepUpObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        endObserver = nil
        failedObserver = nil
        stalledObserver = nil
    }

    private func handleEnded() {
        if sleepTimerMode == "endOfTrack" {
            fireSleepTimer(reason: "endOfTrack")
            return
        }
        if isQueueActive {
            stateQueue.async { [weak self] in self?.queueEngine.handleEnded() }
        } else {
            emitPlaybackState(.ended, force: true)
            emit(.ended(reason: "finished", requestId: currentRequestId))
        }
    }

    private func loadQueueSong(
        _ song: QueueSong,
        autoplay: Bool,
        startTime: Double?
    ) {
        guard let resolved = sourceResolver.resolveSource(for: song) else {
            emitError(
                code: "invalid_source",
                message: "Cannot resolve audio source for song: \(song.id)"
            )
            return
        }
        dispatchMain { [weak self] in
            guard let self else { return }
            do {
                try self.configureAudioSession()
                if autoplay { try self.activateAudioSession() }
                if let entry = self.scrobbleBuffer.stopTracking() {
                    self.scrobbleSubmitter.submitIfEligible(
                        entry: entry,
                        songDurationSeconds: self.scrobbleBuffer.lastEntryDuration ?? 0
                    )
                }
                self.currentSource = resolved.kind == "native-file"
                    ? .nativeFile(uri: resolved.url.absoluteString, songId: song.id)
                    : .stream(url: resolved.url.absoluteString, songId: song.id)
                self.currentSourceURL = resolved.url
                self.currentSourceKind = resolved.kind
                self.metadata = AudioMetadata(
                    title: song.title,
                    artist: song.artist,
                    album: song.album,
                    duration: song.duration,
                    artworkUrl: song.coverArtId.map {
                        "aonsoku-media://getCoverArt?id=\($0)&size=800"
                    },
                    coverArtId: song.coverArtId
                )
                self.loadedDuration = song.duration
                self.installPlayer(
                    url: resolved.url,
                    kind: resolved.kind,
                    songId: song.id
                )
                self.recoveryController.startProgressMonitoring(
                    generation: self.playbackGeneration,
                    sourceKind: self.recoverySourceKind()
                )
                self.emitPlaybackState(.loading, force: true)
                let begin = {
                    if autoplay {
                        self.player?.play()
                        self.scrobbleBuffer.startTracking(
                            songId: song.id,
                            duration: song.duration
                        )
                        self.scrobbleSubmitter.sendNowPlaying(songId: song.id)
                        self.persistence.startProgressTracking()
                    }
                }
                if let startTime, startTime > 0 {
                    self.player?.seek(to: self.makeTime(startTime)) { _ in begin() }
                } else {
                    begin()
                }
            } catch {
                self.emitError(
                    code: "audio_session_failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func makeQueueSnapshot() -> AudioQueueSnapshot {
        AudioQueueSnapshot(
            contextSongs: queueEngine.contextSongs,
            currentIndex: queueEngine.currentIndex,
            sourceId: queueEngine.sourceId.map {
                AudioQueueSource(type: $0.type, id: $0.id)
            },
            sourceName: queueEngine.sourceName,
            userQueue: queueEngine.userQueue,
            originalContextSongs: queueEngine.originalContextSongs,
            originalUserSongs: queueEngine.originalUserSongs,
            shuffleHistory: queueEngine.shuffleHistory,
            shuffleStartHistory: queueEngine.shuffleStartHistory,
            playedUserQueueHistory: queueEngine.playedUserQueueHistory,
            isInUserQueue: queueEngine.isInUserQueue,
            isShuffleActive: queueEngine.isShuffleActive,
            loopState: AudioRepeatMode(rawValue: queueEngine.loopState.rawValue) ?? .off,
            isPlaying: player?.timeControlStatus == .playing,
            currentTime: currentTime,
            duration: duration,
            currentSongId: queueEngine.currentSong?.id,
            isRestored: queueEngine.isRestored
        )
    }

    private func restorePlaybackState() {
        guard let state = persistence.repository.load(),
              !state.contextSongs.isEmpty else { return }
        stateQueue.sync {
            queueEngine.restoreState(from: state)
            isQueueActive = true
            savedRestoreTime = state.currentTime > 0 ? state.currentTime : nil
        }
    }

    private func setupPersistence() {
        persistence.setStateProvider { [weak self] in
            guard let self, self.isQueueActive else { return nil }
            return self.stateQueue.sync {
                PlaybackPersistState(
                    from: self.queueEngine,
                    currentTime: self.currentTime
                )
            }
        }
    }

    private func playSongIds(_ ids: [String], index: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let songs = self.resolveSongs(ids: ids).map(\.queueSong)
            guard !songs.isEmpty else { return }
            self.setContextQueue(songs: songs, currentIndex: index)
        }
    }

    private func playAlbum(id: String, index: Int, shuffle: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let result = try? AlbumRepository(
                      db: DatabaseManager.shared.dbPool
                  ).getWithSongs(id),
                  !result.songs.isEmpty else { return }
            self.setContextQueue(
                songs: result.songs.map(\.queueSong),
                currentIndex: index,
                sourceId: AudioQueueSource(type: "album", id: id),
                sourceName: result.album.name
            )
            if shuffle { self.setShuffle(true) }
        }
    }

    private func playPlaylist(id: String, index: Int, shuffle: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let detail = try? PlaylistRepository(
                      db: DatabaseManager.shared.dbPool
                  ).getDetailById(id),
                  let data = detail.entriesJson.data(using: .utf8),
                  let entries = try? JSONDecoder().decode(
                      [PlaylistEntryIdentifier].self,
                      from: data
                  ) else { return }
            let ids = entries.map(\.id)
            let songs = self.resolveSongs(ids: ids).map(\.queueSong)
            self.setContextQueue(
                songs: songs,
                currentIndex: index,
                sourceId: AudioQueueSource(type: "playlist", id: id),
                sourceName: detail.name
            )
            if shuffle { self.setShuffle(true) }
        }
    }

    private func addSongIds(_ ids: [String], position: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let songs = self.resolveSongs(ids: ids).map(\.queueSong)
            self.addToUserQueue(songs: songs, position: position)
        }
    }

    private func toggleLike() {
        stateQueue.async { [weak self] in
            guard let self, let song = self.queueEngine.currentSong else { return }
            let repository = SongRepository(db: DatabaseManager.shared.dbPool)
            guard let record = try? repository.getById(song.id) else { return }
            let next = record.starredAt == nil
                ? Int(Date().timeIntervalSince1970)
                : nil
            try? repository.updateStarred(
                ids: [song.id],
                starred: next.map(String.init),
                starredAt: next
            )
            self.setLikeActive(next != nil)
        }
    }

    private func configureAudioSession() throws {
        try audioSession.setCategory(
            .playback,
            mode: .default,
            options: [.allowAirPlay, .allowBluetoothA2DP]
        )
    }

    private func activateAudioSession() throws {
        try audioSession.setActive(true)
    }

    private func registerAudioSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in self?.handleInterruption(note) }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey]
                as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            self?.emit(.routeChanged(reason: String(describing: reason)))
        }
    }

    private func removeAudioSessionObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        interruptionObserver = nil
        routeObserver = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
            as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            emit(.interruptionChanged(type: "began", shouldResume: nil))
            pause()
        } else {
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(
                rawValue: optionsRaw
            ).contains(.shouldResume)
            emit(.interruptionChanged(type: "ended", shouldResume: shouldResume))
            if shouldResume { play() }
        }
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        addTarget(center.playCommand) { [weak self] _ in self?.play(); return .success }
        addTarget(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        addTarget(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.remoteProjection != nil {
                self.emit(.remoteCommand(command: "togglePlayPause", position: nil))
            } else {
                _ = self.execute(.togglePlayPause)
            }
            return .success
        }
        addTarget(center.nextTrackCommand) { [weak self] _ in
            self?.routeRemoteOrLocal(command: "next", local: .next)
            return .success
        }
        addTarget(center.previousTrackCommand) { [weak self] _ in
            self?.routeRemoteOrLocal(command: "previous", local: .previous)
            return .success
        }
        addTarget(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            if self?.remoteProjection != nil {
                self?.emit(.remoteCommand(command: "seek", position: event.positionTime))
            } else {
                self?.seek(to: event.positionTime)
            }
            return .success
        }
        addTarget(center.likeCommand) { [weak self] _ in
            self?.routeRemoteOrLocal(command: "like", local: .toggleLike)
            return .success
        }
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget(handler: handler)
        remoteTargets.append((command, target))
    }

    private func unregisterRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
    }

    private func routeRemoteOrLocal(command: String, local: AudioCommand) {
        if remoteProjection != nil {
            emit(.remoteCommand(command: command, position: nil))
        } else {
            _ = execute(local)
        }
    }

    private func observeSystemVolume() {
        volumeObservation = audioSession.observe(\.outputVolume, options: [.new]) {
            [weak self] _, change in
            guard let volume = change.newValue else { return }
            self?.emit(.systemVolumeChanged(volume))
        }
    }

    private func updateNowPlayingInfo() {
        let projection = remoteProjection
        let displayedMetadata = projection?.metadata ?? metadata
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = displayedMetadata.title
        info[MPMediaItemPropertyArtist] = displayedMetadata.artist
        info[MPMediaItemPropertyAlbumTitle] = displayedMetadata.album
        info[MPMediaItemPropertyPlaybackDuration] = projection?.duration ?? duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = projection?.position ?? currentTime
        let isPlaying = projection?.isPlaying ?? ((player?.rate ?? 0) > 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1 : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackInfo() {
        updateNowPlayingInfo()
    }

    private func emitPlaybackState(
        _ state: AudioPlaybackSnapshot.State,
        force: Bool = false
    ) {
        if !force && playbackState == state { return }
        playbackState = state
        emit(.playbackStateChanged(state, requestId: currentRequestId))
        updateNowPlayingPlaybackInfo()
        publishStateUpdate()
        NotificationCenter.default.post(name: .aonsokuAudioStateDidChange, object: self)
    }

    private func emitProgress() {
        emit(.progress(
            currentTime: currentTime,
            duration: duration,
            bufferedTime: bufferedTime,
            requestId: currentRequestId
        ))
        publishStateUpdate()
    }

    private func emitDuration() {
        guard duration > 0 else { return }
        emit(.durationChanged(duration, requestId: currentRequestId))
    }

    private func emitError(
        code: String,
        message: String,
        requestId: String? = nil
    ) {
        NativeLogger.shared.error("[\(code)] \(message)", source: "AudioService")
        emit(.error(
            code: code,
            message: message,
            requestId: requestId ?? currentRequestId
        ))
    }

    private func emit(_ event: AudioServiceEvent) {
        let handlers = listenerQueue.sync { Array(listeners.values) }
        for handler in handlers { handler(event) }
    }

    private func publishStateUpdate() {
        dispatchMain { [weak self] in
            guard let self else { return }
            let snapshot = self.playbackSnapshot()
            let handlers = self.listenerQueue.sync {
                Array(self.stateListeners.values)
            }
            for handler in handlers { handler(snapshot) }
        }
    }

    private var currentTime: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    private var duration: Double {
        let itemDuration = playerItem?.duration.seconds ?? 0
        if itemDuration.isFinite, itemDuration > 0 { return itemDuration }
        return loadedDuration ?? 0
    }

    private var bufferedTime: Double {
        playerItem?.loadedTimeRanges.compactMap { range -> Double? in
            guard let value = range.timeRangeValue as CMTimeRange? else { return nil }
            let end = value.start.seconds + value.duration.seconds
            return end.isFinite ? end : nil
        }.max() ?? 0
    }

    private var isAtEnd: Bool {
        duration > 0 && currentTime >= duration - 0.25
    }

    private func resolve(_ source: AudioSource) throws -> (url: URL, kind: String) {
        switch source {
        case .nativeFile(let uri, _):
            guard let url = URL(string: uri), url.isFileURL else {
                throw AudioServiceError(
                    code: "invalid_source",
                    message: "Native audio source must be a file URL."
                )
            }
            return (url, "native-file")
        case .blob(let url, _), .radio(let url, _):
            guard let resolved = URL(string: url) else {
                throw AudioServiceError(code: "invalid_source", message: "Invalid audio URL.")
            }
            return (resolved, Self.sourceKind(source))
        case .stream(let rawURL, let songId):
            if let songId,
               let resolved = sourceResolver.resolveSource(
                   for: QueueSong(
                       id: songId,
                       title: "",
                       artist: "",
                       album: "",
                       duration: 0,
                       streamUrl: rawURL
                   )
               ) {
                return resolved
            }
            guard let url = URL(string: rawURL) else {
                throw AudioServiceError(code: "invalid_source", message: "Invalid stream URL.")
            }
            return (url, "stream")
        }
    }

    private func startBackgroundCache(songId: String) {
        let cacheId = AudioCacheUtils.cacheId(for: songId)
        let extensions = [
            "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio",
        ]
        for directory in sourceResolver.cacheDirectories {
            for fileExtension in extensions where FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("\(cacheId).\(fileExtension)")
                    .path
            ) {
                return
            }
        }
        guard backgroundCacheSongIds.insert(songId).inserted else { return }
        downloadManager.download(songId: songId)
    }

    private func checkEndOfStreamAfterCacheComplete(songId: String) {
        guard isQueueActive,
              queueEngine.currentSong?.id == songId,
              let player,
              let playerItem,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              playerItem.isPlaybackBufferEmpty else { return }
        backgroundCacheCompletedSongIds.remove(songId)
        NativeLogger.shared.info(
            "End of stream detected after cache completion for \(songId)",
            source: "AudioService"
        )
        handleEnded()
    }

    private func recoverySourceKind() -> RecoverySourceKind {
        switch currentSourceKind {
        case "radio": return .radio
        case "native-file": return .nativeFile
        default: return .stream
        }
    }

    private func cachedFile(
        songId: String,
        fileURL: URL,
        contentType: String?,
        lastModifiedAt: Double?
    ) -> CachedAudioFile {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        return CachedAudioFile(
            songId: songId,
            uri: fileURL.absoluteString,
            contentType: contentType,
            sizeBytes: (attributes?[.size] as? NSNumber)?.int64Value,
            lastModifiedAt: lastModifiedAt
        )
    }

    private func fireSleepTimer(reason: String) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndDate = nil
        sleepTimerMode = "duration"
        player?.pause()
        emitPlaybackState(.paused)
        emit(.sleepTimerFired(reason: reason))
    }

    private func makeTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    private func dispatchMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private func dispatchMainSync(_ work: () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.sync(execute: work) }
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        return view.subviews.lazy.compactMap(findSlider(in:)).first
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func sourceKind(_ source: AudioSource) -> String {
        switch source {
        case .radio: return "radio"
        case .nativeFile: return "native-file"
        case .stream, .blob: return "stream"
        }
    }

    private static func songId(_ source: AudioSource) -> String? {
        switch source {
        case .stream(_, let songId),
             .blob(_, let songId),
             .nativeFile(_, let songId):
            return songId
        case .radio(_, let radioId):
            return radioId
        }
    }

    private static func queueSong(
        source: AudioSource,
        metadata: AudioMetadata,
        fallbackId: String
    ) -> QueueSong {
        let sourceURL: String
        let id: String
        switch source {
        case .stream(let url, let songId), .blob(let url, let songId):
            sourceURL = url
            id = songId ?? fallbackId
        case .nativeFile(let uri, let songId):
            sourceURL = uri
            id = songId ?? fallbackId
        case .radio(let url, let radioId):
            sourceURL = url
            id = radioId ?? fallbackId
        }
        return QueueSong(
            id: id,
            title: metadata.title ?? "",
            artist: metadata.artist ?? "",
            album: metadata.album ?? "",
            duration: metadata.duration ?? 0,
            coverArtId: metadata.coverArtId,
            streamUrl: sourceURL
        )
    }
}

extension AudioService: NativeQueueEngineDelegate {
    func queueEngine(
        _ engine: NativeQueueEngine,
        loadSong song: QueueSong,
        autoplay: Bool,
        startTime: Double?
    ) {
        loadQueueSong(song, autoplay: autoplay, startTime: startTime)
    }

    func queueEngine(
        _ engine: NativeQueueEngine,
        didAdvanceTo index: Int,
        songId: String,
        reason: QueueAdvanceReason
    ) {
        persistence.markStateDirty()
        emit(.queueStateChanged(
            index: index,
            songId: songId,
            reason: reason.rawValue,
            isInUserQueue: engine.isInUserQueue
        ))
        publishStateUpdate()
        NotificationCenter.default.post(name: .aonsokuAudioStateDidChange, object: self)
    }

    func queueEngine(
        _ engine: NativeQueueEngine,
        didChangeContents reason: String
    ) {
        persistence.markStateDirty()
        emit(.queueContentsChanged(reason: reason))
        publishStateUpdate()
        NotificationCenter.default.post(name: .aonsokuAudioStateDidChange, object: self)
    }

    func queueEngineDidExhaustQueue(_ engine: NativeQueueEngine) {
        dispatchMain { [weak self] in
            self?.player?.pause()
            self?.player?.seek(to: .zero)
            self?.emitPlaybackState(.ended, force: true)
            self?.emit(.ended(reason: "finished", requestId: self?.currentRequestId))
        }
    }

    func queueEngine(
        _ engine: NativeQueueEngine,
        seekToStart song: QueueSong
    ) {
        dispatchMain { [weak self] in
            self?.player?.seek(to: .zero) { _ in self?.player?.play() }
        }
    }
}

extension AudioService: PlaybackRecoveryDelegate {
    func recoverySeek(
        _ controller: PlaybackRecoveryController,
        to time: CMTime,
        generation: Int
    ) {
        guard generation == playbackGeneration, let player else { return }
        if case .level1(let attempt) = controller.state {
            emit(.recoveryAttempt(level: 1, attempt: attempt, maxAttempts: 3))
        }
        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] finished in
            guard finished,
                  let self,
                  let player,
                  generation == self.playbackGeneration else { return }
            player.play()
        }
    }

    func recoveryReload(
        _ controller: PlaybackRecoveryController,
        generation: Int,
        savedPosition: CMTime
    ) {
        guard generation == playbackGeneration else {
            controller.reloadDidComplete(success: false, generation: generation)
            return
        }
        if case .level2(let attempt) = controller.state {
            emit(.recoveryAttempt(level: 2, attempt: attempt, maxAttempts: 2))
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.sourceResolver.invalidateCredentialsCache()
            let resolved: (url: URL, kind: String)?
            if self.isQueueActive, let song = self.stateQueue.sync(
                execute: { self.queueEngine.currentSong }
            ) {
                resolved = self.sourceResolver.resolveSource(for: song)
            } else if let source = self.currentSource,
                      let source = try? self.resolve(source) {
                resolved = source
            } else {
                resolved = nil
            }
            DispatchQueue.main.async {
                guard generation == self.playbackGeneration,
                      let resolved,
                      let player = self.player else {
                    controller.reloadDidComplete(
                        success: false,
                        generation: generation
                    )
                    return
                }
                self.isRecoveryReload = true
                self.removePlayerObservers()
                let item = AVPlayerItem(url: resolved.url)
                item.preferredForwardBufferDuration = resolved.kind == "radio"
                    ? 0
                    : .greatestFiniteMagnitude
                player.replaceCurrentItem(with: item)
                self.playerItem = item
                self.currentSourceURL = resolved.url
                self.currentSourceKind = resolved.kind
                self.observe(item: item, player: player, generation: generation)
                player.seek(
                    to: savedPosition,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { [weak self, weak player] finished in
                    guard let self,
                          let player,
                          generation == self.playbackGeneration else {
                        controller.reloadDidComplete(
                            success: false,
                            generation: generation
                        )
                        return
                    }
                    self.isRecoveryReload = false
                    if finished {
                        player.play()
                    }
                    controller.reloadDidComplete(
                        success: finished,
                        generation: generation
                    )
                }
            }
        }
    }

    func recoveryExhausted(
        _ controller: PlaybackRecoveryController,
        generation: Int
    ) {
        guard generation == playbackGeneration else { return }
        isRecoveryReload = false
        if isQueueActive, stateQueue.sync(execute: { queueEngine.hasNext }) {
            stateQueue.async { [weak self] in self?.queueEngine.skipToNext() }
        } else {
            emitError(
                code: "recovery_failed",
                message: "Playback recovery exhausted all attempts."
            )
            emitPlaybackState(.failed, force: true)
        }
    }

    func recoverySetBuffering(
        _ controller: PlaybackRecoveryController,
        isBuffering: Bool
    ) {
        emit(.bufferingChanged(isBuffering, requestId: currentRequestId))
    }

    func recoveryDidBegin(_ controller: PlaybackRecoveryController) {
        scrobbleBuffer.pauseTracking()
    }

    func recoveryDidSucceed(_ controller: PlaybackRecoveryController) {
        scrobbleBuffer.resumeTracking()
        recoveryController.startProgressMonitoring(
            generation: playbackGeneration,
            sourceKind: recoverySourceKind()
        )
    }
}

extension AudioService: NativeDownloadManagerDelegate {
    func downloadManager(
        _ manager: NativeDownloadManager,
        didProgress songId: String,
        loaded: Int64,
        total: Int64
    ) {
        dispatchMain { [weak self] in
            guard let self,
                  !self.backgroundCacheSongIds.contains(songId) else { return }
            self.emit(.downloadProgress(songId: songId, loaded: loaded, total: total))
        }
    }

    func downloadManager(
        _ manager: NativeDownloadManager,
        didComplete songId: String,
        fileUrl: URL,
        contentType: String,
        sizeBytes: Int64
    ) {
        let file = CachedAudioFile(
            songId: songId,
            uri: fileUrl.absoluteString,
            contentType: contentType,
            sizeBytes: sizeBytes,
            lastModifiedAt: Date().timeIntervalSince1970 * 1000
        )
        dispatchMain { [weak self] in
            guard let self else { return }
            if self.backgroundCacheSongIds.remove(songId) != nil {
                self.backgroundCacheCompletedSongIds.insert(songId)
                self.emit(.streamCacheCompleted(songId: songId, file: file))
                self.checkEndOfStreamAfterCacheComplete(songId: songId)
            } else {
                self.emit(.downloadCompleted(songId: songId, file: file))
            }
        }
    }

    func downloadManager(
        _ manager: NativeDownloadManager,
        didFail songId: String,
        error: Error
    ) {
        dispatchMain { [weak self] in
            guard let self else { return }
            if self.backgroundCacheSongIds.remove(songId) != nil {
                NativeLogger.shared.warn(
                    "Background cache failed for \(songId): \(error.localizedDescription)",
                    source: "AudioService"
                )
                return
            }
            self.emit(.downloadFailed(
                songId: songId,
                message: error.localizedDescription
            ))
        }
    }
}

private struct PlaylistEntryIdentifier: Decodable {
    let id: String
}

private extension SongRecord {
    var queueSong: QueueSong {
        let streamURL: String = {
            var components = URLComponents()
            components.scheme = "aonsoku-media"
            components.host = "stream"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
            return components.string ?? "aonsoku-media://stream?id=\(id)"
        }()
        return QueueSong(
            id: id,
            title: title,
            artist: artist ?? "",
            artistId: artistId,
            album: album ?? "",
            albumId: albumId,
            duration: Double(duration),
            coverArtId: coverArt ?? albumId,
            streamUrl: streamURL
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public extension Notification.Name {
    static let aonsokuAudioStateDidChange = Notification.Name(
        "AonsokuAudioServiceStateDidChange"
    )
}
