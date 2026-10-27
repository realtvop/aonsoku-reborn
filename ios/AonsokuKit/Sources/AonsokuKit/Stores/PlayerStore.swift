import Foundation
import Perception

/// Playback position sampled at a moment, so views can interpolate it with
/// `TimelineView` instead of observing every progress event.
public struct PlaybackClock: Hashable, Sendable {
    /// Seconds into the song when sampled.
    public var position: TimeInterval
    /// Seconds; 0 when unknown (live radio).
    public var duration: TimeInterval
    /// 1 while playing, 0 while paused or buffering.
    public var rate: Double
    /// `ProcessInfo.systemUptime` of the sample.
    public var sampledAt: TimeInterval

    public init(
        position: TimeInterval,
        duration: TimeInterval,
        rate: Double,
        sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.position = position
        self.duration = duration
        self.rate = rate
        self.sampledAt = sampledAt
    }

    public static let zero = PlaybackClock(position: 0, duration: 0, rate: 0, sampledAt: 0)

    /// The position at `uptime`, clamped to the duration when known.
    public func position(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> TimeInterval
    {
        let elapsed = max(0, uptime - sampledAt) * rate
        let value = max(0, position + elapsed)
        return duration > 0 ? min(value, duration) : value
    }

    /// 0...1 at `uptime`; 0 when the duration is unknown.
    public func progress(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard duration > 0 else { return 0 }
        return position(at: uptime) / duration
    }
}

/// What a controlled device is playing, as projected from its coordination
/// snapshots.
public struct RemoteNowPlaying: Hashable, Sendable {
    public var deviceId: String
    public var deviceName: String
    public var song: Song?
    public var queue: PlayerQueue
    public var isPlaying: Bool
    public var clock: PlaybackClock
    public var isShuffleActive: Bool
    public var repeatMode: AudioRepeatMode
    /// 0...1, when the device reports it.
    public var volume: Double?

    public init(
        deviceId: String,
        deviceName: String,
        song: Song? = nil,
        queue: PlayerQueue = .empty,
        isPlaying: Bool = false,
        clock: PlaybackClock = .zero,
        isShuffleActive: Bool = false,
        repeatMode: AudioRepeatMode = .off,
        volume: Double? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.song = song
        self.queue = queue
        self.isPlaying = isPlaying
        self.clock = clock
        self.isShuffleActive = isShuffleActive
        self.repeatMode = repeatMode
        self.volume = volume
    }
}

/// Remote playback the player controls instead of local audio.
/// `CoordinationStore` implements it.
@MainActor
public protocol RemotePlaybackSource: AnyObject {
    /// The controlled device's playback; nil while playing locally.
    var remoteNowPlaying: RemoteNowPlaying? { get }
    /// Sends a command to the controlled device and waits for its
    /// acknowledgement.
    func send(_ command: CoordinationRemoteCommand) async throws
}

/// The player for the UI: local playback through `AudioService`, or the
/// controlled device while `remote` reports one. Every property reflects the
/// current target, so views do not branch on local versus remote.
///
/// Mirrors the web player store (`src/store/player/`): context and user
/// queues, shuffle and repeat, queue replacement confirmation, radio, sleep
/// timer, ReplayGain and the system volume.
@MainActor
@Perceptible
public final class PlayerStore {
    // MARK: Local state

    /// The local song; read `currentSong` for the remote-aware value.
    public private(set) var localSong: Song?
    /// The local radio station, when radio is playing.
    public private(set) var radio: RadioPlayback?
    /// Playback intent, including automatic loading and buffering.
    public private(set) var localIsPlaying = false
    public private(set) var isBuffering = false
    public private(set) var localClock = PlaybackClock.zero
    public private(set) var localQueue = PlayerQueue.empty
    public private(set) var localShuffle = false
    public private(set) var localRepeatMode = AudioRepeatMode.off
    /// System output volume, 0...1.
    public private(set) var localVolume: Double = 1
    public private(set) var sleepTimer = SleepTimerState.off
    /// The last playback error, cleared when playback resumes.
    public private(set) var errorMessage: String?
    /// A play request waiting for the user to confirm replacing the songs
    /// they queued. The UI shows a dialog and calls `resolveReplacement`.
    public private(set) var pendingReplacement: QueueReplacementRequest?
    /// Counts selections that started playing here or on the controlled
    /// device (a song, album, playlist, artist or station), so the UI can
    /// open Now Playing when `PlaybackSettings.autoOpenNowPlaying` is on.
    /// Queue navigation and resuming do not count.
    public private(set) var playbackStarts = 0

    @PerceptionIgnored public weak var remote: (any RemotePlaybackSource)?
    /// Toggles the current song's favorite (lock screen Like and the player
    /// heart). Set by the app model.
    @PerceptionIgnored public weak var favorites: FavoritesStore?

    @PerceptionIgnored public let audio: AudioService
    @PerceptionIgnored public let repository: LibraryRepository
    @PerceptionIgnored public let settings: SettingsStore
    @PerceptionIgnored public let authentication: AuthenticationService
    @PerceptionIgnored private let playbackSnapshot: @Sendable () -> AudioPlaybackSnapshot
    @PerceptionIgnored private var localPlaybackState: AudioPlaybackSnapshot.State = .idle
    @PerceptionIgnored private var audioSubscription: UUID?
    @PerceptionIgnored private var songCache: [String: Song] = [:]
    @PerceptionIgnored private var lastProgressSample = 0.0
    @PerceptionIgnored private var lastSnapshot: AudioQueueSnapshot?
    @PerceptionIgnored private var refreshGeneration = 0
    @PerceptionIgnored private var selectionGeneration = 0
    /// Song ids whose repository lookup is running, so overlapping queue
    /// refreshes do not look up the same song twice.
    @PerceptionIgnored private var enrichingSongIds = Set<String>()
    /// Bumped only by `clearAll()`: a lookup that started under an earlier
    /// value belongs to the previous account and must not touch the cache.
    @PerceptionIgnored private var enrichmentGeneration = 0

    public init(
        audio: AudioService,
        repository: LibraryRepository,
        settings: SettingsStore,
        authentication: AuthenticationService
    ) {
        self.audio = audio
        self.repository = repository
        self.settings = settings
        self.authentication = authentication
        self.playbackSnapshot = { audio.playbackSnapshot() }
    }

    init(
        audio: AudioService,
        repository: LibraryRepository,
        settings: SettingsStore,
        authentication: AuthenticationService,
        playbackSnapshot: @escaping @Sendable () -> AudioPlaybackSnapshot
    ) {
        self.audio = audio
        self.repository = repository
        self.settings = settings
        self.authentication = authentication
        self.playbackSnapshot = playbackSnapshot
    }

    // MARK: Target-aware state

    public var remoteNowPlaying: RemoteNowPlaying? { remote?.remoteNowPlaying }

    public var target: PlaybackTarget {
        guard let remote = remoteNowPlaying else { return .local }
        return .remote(deviceId: remote.deviceId, deviceName: remote.deviceName)
    }

    public var currentSong: Song? { remoteNowPlaying.map(\.song) ?? localSong }
    public var isPlaying: Bool { remoteNowPlaying?.isPlaying ?? localIsPlaying }
    public var clock: PlaybackClock { remoteNowPlaying?.clock ?? localClock }
    public var queue: PlayerQueue { remoteNowPlaying?.queue ?? localQueue }
    public var isShuffleActive: Bool { remoteNowPlaying?.isShuffleActive ?? localShuffle }
    public var repeatMode: AudioRepeatMode { remoteNowPlaying?.repeatMode ?? localRepeatMode }
    public var volume: Double { remoteNowPlaying.map { $0.volume ?? 1 } ?? localVolume }

    /// Something is loaded: a song, a radio station or remote playback.
    public var hasMedia: Bool {
        remoteNowPlaying != nil || localSong != nil || radio != nil
    }

    /// Radio has no queue, seeking, shuffle or repeat.
    public var isRadio: Bool { remoteNowPlaying == nil && radio != nil }

    // MARK: Lifecycle

    /// Subscribes to `AudioService` and adopts the restored queue. Call once
    /// after sign-in.
    public func start() {
        guard audioSubscription == nil else { return }
        audioSubscription = audio.subscribe { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }

        localVolume = Double(audio.systemVolume)
        let remaining = audio.sleepTimerRemaining
        if remaining > 0 {
            sleepTimer = .countdown(endsAt: Date().addingTimeInterval(remaining))
        }
        refreshFromAudio(enrich: true)
    }

    /// Stops playback and clears the queue and its saved state (sign-out).
    public func clearAll() {
        refreshGeneration += 1
        selectionGeneration += 1
        enrichmentGeneration += 1
        enrichingSongIds.removeAll()
        audio.stop()
        audio.cancelSleepTimer()
        audio.clear()
        songCache = [:]
        lastSnapshot = nil
        localSong = nil
        radio = nil
        localPlaybackState = .idle
        localIsPlaying = false
        isBuffering = false
        localClock = .zero
        localQueue = .empty
        localShuffle = false
        localRepeatMode = .off
        localVolume = Double(audio.systemVolume)
        sleepTimer = .off
        errorMessage = nil
        pendingReplacement = nil
        lastProgressSample = 0
        audio.setLikeActive(false)
    }

    // MARK: Starting playback

    /// Plays `songs` from `index`, replacing the context queue. When songs
    /// the user queued would be lost while playing, sets
    /// `pendingReplacement` instead, unless `confirmed` is true.
    public func play(
        _ songs: [Song],
        startingAt index: Int? = nil,
        shuffle: Bool = false,
        source: QueueSource? = nil,
        sourceName: String? = nil,
        confirmed: Bool = false
    ) {
        selectionGeneration += 1
        guard !songs.isEmpty else { return }
        let requestedIndex = index ?? (shuffle ? randomShuffleStartIndex(for: songs) : 0)
        let clampedIndex = min(max(requestedIndex, 0), songs.count - 1)

        if !shuffle,
            isSameContext(
                songs: songs,
                index: clampedIndex,
                source: source
            )
        {
            resume()
            return
        }

        if !confirmed, shouldConfirmReplacement {
            pendingReplacement = QueueReplacementRequest(
                content: .songs(
                    songs,
                    index: clampedIndex,
                    shuffle: shuffle,
                    source: source,
                    sourceName: sourceName
                ),
                targetDeviceId: target.remoteDeviceId
            )
            return
        }

        if target.isRemote {
            sendRemotePlayback(
                songs: songs,
                index: clampedIndex,
                shuffle: shuffle,
                source: source
            )
            playbackStarts += 1
            return
        }

        startLocalPlayback(
            songs: songs,
            index: clampedIndex,
            shuffle: shuffle,
            source: source,
            sourceName: sourceName
        )
    }

    /// Plays one song on its own (search results, song links).
    public func play(song: Song, sourceName: String? = nil, confirmed: Bool = false) {
        selectionGeneration += 1
        if !confirmed, isSameContext(songs: [song], index: 0, source: nil) {
            resume()
            return
        }
        if !confirmed, shouldConfirmReplacement {
            pendingReplacement = QueueReplacementRequest(
                content: .song(song, sourceName: sourceName),
                targetDeviceId: target.remoteDeviceId
            )
            return
        }
        play(
            [song],
            sourceName: sourceName,
            confirmed: true
        )
    }

    /// Loads the album and plays it.
    public func playAlbum(id: String, startingAt index: Int? = nil, shuffle: Bool = false) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        do {
            let detail = try await repository.album(id: id)
            guard generation == selectionGeneration else { return }
            play(
                detail.songs,
                startingAt: index,
                shuffle: shuffle,
                source: .album(id),
                sourceName: detail.album.name
            )
        } catch {
            guard generation == selectionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func playPlaylist(id: String, startingAt index: Int? = nil, shuffle: Bool = false) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        do {
            let detail = try await repository.playlist(id: id)
            guard generation == selectionGeneration else { return }
            play(
                detail.songs,
                startingAt: index,
                shuffle: shuffle,
                source: .playlist(id),
                sourceName: detail.playlist.name
            )
        } catch {
            guard generation == selectionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Plays every song by the artist (web artist play button).
    public func playArtist(id: String, name: String, shuffle: Bool = false) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        do {
            let page = try await repository.songs(
                SongListQuery(scope: .artist(id: id, name: name)),
                offset: 0,
                limit: 10_000
            )
            guard generation == selectionGeneration else { return }
            play(
                page.items,
                shuffle: shuffle,
                source: .artist(id),
                sourceName: name
            )
        } catch {
            guard generation == selectionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Plays `stations[index]`. Next and previous move between stations.
    public func playRadio(_ stations: [RadioStation], index: Int) {
        selectionGeneration += 1
        loadRadio(stations, index: index, countStart: true)
    }

    private func loadRadio(
        _ stations: [RadioStation],
        index: Int,
        countStart: Bool
    ) {
        guard !stations.isEmpty else { return }
        let wrappedIndex = ((index % stations.count) + stations.count) % stations.count
        let station = stations[wrappedIndex]
        let request = AudioLoadRequest(
            source: .radio(url: station.streamUrl, radioId: station.id),
            metadata: AudioMetadata(title: station.name),
            autoplay: true,
            requestId: "radio:\(station.id)"
        )
        radio = RadioPlayback(stations: stations, index: wrappedIndex)
        localSong = nil
        localQueue = .empty
        localShuffle = false
        localRepeatMode = .off
        errorMessage = nil
        if countStart { playbackStarts += 1 }
        audio.load(request) { [weak self] result in
            guard case .failure(let error) = result else { return }
            Task { @MainActor [weak self] in
                self?.errorMessage = error.message
            }
        }
    }

    /// Answers `pendingReplacement`.
    public func resolveReplacement(_ choice: QueueReplacementChoice) {
        guard let request = pendingReplacement else { return }
        pendingReplacement = nil
        guard request.targetDeviceId == target.remoteDeviceId else { return }

        switch choice {
        case .cancel:
            return
        case .replace:
            if target.isRemote {
                let commands: [CoordinationRemoteCommand]
                switch request.content {
                case .song(let song, _):
                    commands = remotePlaybackCommands(
                        songs: [song],
                        index: 0,
                        shuffle: false,
                        source: nil
                    )
                case .songs(let songs, let index, let shuffle, let source, _):
                    commands = remotePlaybackCommands(
                        songs: songs,
                        index: index,
                        shuffle: shuffle,
                        source: source
                    )
                }
                sendRemoteSequence([.clearQueue] + commands)
                playbackStarts += 1
                return
            } else {
                audio.clearUserQueue()
            }
            switch request.content {
            case .song(let song, let sourceName):
                play(song: song, sourceName: sourceName, confirmed: true)
            case .songs(let songs, let index, let shuffle, let source, let sourceName):
                play(
                    songs,
                    startingAt: index,
                    shuffle: shuffle,
                    source: source,
                    sourceName: sourceName,
                    confirmed: true
                )
            }
        case .playNext:
            let songs = request.playNextSongs()
            guard !songs.isEmpty else { return }
            enqueueAndStart(songs)
        }
    }

    /// Play Next (`.next`) or Add to Queue (`.last`).
    public func enqueue(_ songs: [Song], position: QueueInsertPosition) {
        guard !songs.isEmpty else { return }
        if !hasMedia {
            play(songs, confirmed: true)
            return
        }
        if target.isRemote {
            let ids = songs.map(\.id)
            sendRemote(
                position == .next
                    ? .addToQueueNext(songIds: ids)
                    : .addToQueueLast(songIds: ids))
            return
        }
        let converted = queueSongs(from: songs)
        guard !converted.isEmpty else { return }
        audio.addToUserQueue(songs: converted, position: position.rawValue)
    }

    // MARK: Transport

    public func togglePlayPause() {
        if target.isRemote {
            sendRemote(.togglePlayPause)
        } else if localIsPlaying {
            pause()
        } else {
            resume()
        }
    }

    public func resume() {
        if target.isRemote { sendRemote(.play) } else { audio.play() }
    }

    public func pause() {
        if target.isRemote { sendRemote(.pause) } else { audio.pause() }
    }

    public func next() {
        selectionGeneration += 1
        if target.isRemote {
            sendRemote(.next)
        } else if let radio {
            loadRadio(radio.stations, index: radio.index + 1, countStart: false)
        } else {
            audio.skipToNext()
        }
    }
    /// Restarts the song after three seconds, otherwise goes back.
    public func previous() {
        selectionGeneration += 1
        if target.isRemote {
            sendRemote(.previous)
        } else if let radio {
            loadRadio(radio.stations, index: radio.index - 1, countStart: false)
        } else {
            audio.skipToPrevious()
        }
    }

    public func seek(to seconds: TimeInterval) {
        let value = max(0, seconds)
        if target.isRemote {
            sendRemote(.seek(seconds: value))
        } else if !isRadio {
            localClock = PlaybackClock(
                position: value,
                duration: localClock.duration,
                rate: localPlaybackState == .playing && !isBuffering ? 1 : 0
            )
            audio.seek(to: value)
        }
    }

    public func toggleShuffle() {
        if target.isRemote {
            sendRemote(.setShuffle(!isShuffleActive))
        } else if !isRadio {
            audio.setShuffle(!localShuffle)
        }
    }
    /// Off, all, one, off.
    public func cycleRepeat() {
        let next = repeatMode.next
        if target.isRemote {
            sendRemote(.setRepeat(CoordinationRepeatMode(rawValue: next.rawValue) ?? .off))
        } else if !isRadio {
            audio.setRepeatMode(next)
        }
    }
    /// System volume 0...1 (local), or the controlled device's volume.
    public func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        if target.isRemote {
            sendRemote(.setVolume(clamped))
        } else {
            audio.setSystemVolume(clamped) { [weak self] result in
                guard case .failure(let error) = result else { return }
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.message
                }
            }
        }
    }

    // MARK: Queue

    /// Jumps to a queue row.
    public func play(entry: QueueEntry) {
        selectionGeneration += 1
        if target.isRemote {
            let contextCurrent = queue.current.flatMap {
                $0.tier == .context ? $0 : nil
            }
            let entries = entry.tier == .context
                ? queue.history + Array(contextCurrent.map { [$0] } ?? []) + queue.upNext
                : queue.userQueue
            let ids = entries.map(\.song.id)
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            sendRemote(.playAtIndex(songIds: ids, index: index))
            return
        }
        switch entry.tier {
        case .context:
            audio.playAtIndex(entry.index)
        case .user:
            guard let snapshot = lastSnapshot else { return }
            if snapshot.isInUserQueue {
                let between = Array(1..<max(1, entry.index))
                if !between.isEmpty { audio.removeFromUserQueue(indices: between) }
            } else if entry.index > 0 {
                audio.removeFromUserQueue(indices: Array(0..<entry.index))
            }
            audio.skipToNext()
        }
    }

    /// Plays a history song next and starts it (web history rows).
    public func playFromHistory(_ song: Song) {
        selectionGeneration += 1
        enqueueAndStart([song])
    }

    public func remove(entries: [QueueEntry]) {
        guard !entries.isEmpty else { return }
        if target.isRemote {
            sendRemote(.removeFromQueue(songIds: entries.map(\.song.id)))
            return
        }
        guard let snapshot = lastSnapshot else { return }
        let userIndices = entries.filter { $0.tier == .user }.map(\.index)
        if !userIndices.isEmpty { audio.removeFromUserQueue(indices: userIndices) }

        let contextIndices = Set(entries.filter { $0.tier == .context }.map(\.index))
        guard !contextIndices.isEmpty else { return }
        let retainedEntries = snapshot.contextSongs.enumerated().filter {
            !contextIndices.contains($0.offset) || $0.offset == snapshot.currentIndex
        }
        let retained = retainedEntries.map(\.element)
        guard !retained.isEmpty else { return }
        let currentIndex = retainedEntries.firstIndex {
            $0.offset == snapshot.currentIndex
        } ?? 0
        audio.updateContextQueue(songs: retained, currentIndex: currentIndex)
    }

    /// Reorders rows within one tier, using `List.onMove` offsets relative
    /// to that tier's rows as shown.
    public func move(in tier: QueueTier, from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        if target.isRemote {
            guard source.count == 1, let from = source.first else { return }
            let entries = tier == .context ? queue.upNext : queue.userQueue
            guard entries.indices.contains(from) else { return }
            let adjusted = destination > from ? destination - 1 : destination
            guard entries.indices.contains(max(0, min(adjusted, entries.count - 1))) else { return }
            let to = max(0, min(adjusted, entries.count - 1))
            sendRemote(
                .reorderQueue(
                    from: flattenedRemoteQueueIndex(for: entries[from]),
                    to: flattenedRemoteQueueIndex(for: entries[to])
                ))
            return
        }
        guard let snapshot = lastSnapshot else { return }
        switch tier {
        case .context:
            var upcoming = Array(snapshot.contextSongs.dropFirst(snapshot.currentIndex + 1))
            reorder(&upcoming, from: source, to: destination)
            let retained = Array(snapshot.contextSongs.prefix(snapshot.currentIndex + 1))
            audio.updateContextQueue(
                songs: retained + upcoming,
                currentIndex: snapshot.currentIndex
            )
        case .user:
            let hiddenCurrent = snapshot.isInUserQueue ? 1 : 0
            var visible = Array(snapshot.userQueue.dropFirst(hiddenCurrent))
            reorder(&visible, from: source, to: destination)
            if snapshot.isInUserQueue {
                let indices = Array(1..<snapshot.userQueue.count)
                if !indices.isEmpty { audio.removeFromUserQueue(indices: indices) }
                if !visible.isEmpty { audio.addToUserQueue(songs: visible, position: "last") }
            } else {
                audio.clearUserQueue()
                if !visible.isEmpty { audio.addToUserQueue(songs: visible, position: "last") }
            }
        }
    }

    private func flattenedRemoteQueueIndex(for entry: QueueEntry) -> Int {
        let contextPlayedCount = queue.history.count
            + (queue.current?.tier == .context ? 1 : 0)
        let fullUserCount = queue.userQueue.count
            + (queue.current?.tier == .user ? 1 : 0)
        switch entry.tier {
        case .user:
            return contextPlayedCount + entry.index
        case .context:
            return entry.index + fullUserCount
        }
    }

    /// Clears the songs the user queued and the rest of the context queue,
    /// keeping the current song.
    public func clearQueue() {
        if target.isRemote {
            sendRemote(.clearQueue)
            return
        }
        guard let snapshot = lastSnapshot, let currentId = snapshot.currentSongId else {
            audio.clearUserQueue()
            return
        }
        if snapshot.isInUserQueue, let current = snapshot.userQueue.first {
            audio.clearUserQueue()
            audio.setContextQueue(
                songs: [current],
                currentIndex: 0,
                autoplay: snapshot.isPlaying,
                startTime: snapshot.currentTime,
                repeatMode: snapshot.loopState
            )
        } else {
            audio.clearUserQueue()
            let kept = Array(snapshot.contextSongs.prefix(snapshot.currentIndex + 1))
            let index = kept.firstIndex { $0.id == currentId } ?? max(0, kept.count - 1)
            if !kept.isEmpty { audio.updateContextQueue(songs: kept, currentIndex: index) }
        }
    }

    // MARK: Sleep timer

    public func setSleepTimer(minutes: Int) {
        let seconds = Double(max(0, minutes) * 60)
        guard seconds > 0 else {
            cancelSleepTimer()
            return
        }
        sleepTimer = .countdown(endsAt: Date().addingTimeInterval(seconds))
        audio.setSleepTimer(seconds: seconds, mode: "duration")
    }

    public func setSleepTimerEndOfTrack() {
        sleepTimer = .endOfTrack
        audio.setSleepTimer(seconds: 0, mode: "endOfTrack")
    }

    public func cancelSleepTimer() {
        sleepTimer = .off
        audio.cancelSleepTimer()
    }

    // MARK: Favorites

    public func toggleFavoriteCurrent() async {
        guard let song = currentSong, let favorites else { return }
        await favorites.toggle(.song, id: song.id)
        audio.setLikeActive(favorites.isFavorite(.song, id: song.id))
    }

    // MARK: Audio adaptation

    private var shouldConfirmReplacement: Bool {
        isPlaying && !queue.userQueue.isEmpty
    }

    private func handle(_ event: AudioServiceEvent) {
        switch event {
        case .playbackStateChanged(let state, _):
            localPlaybackState = state
            localIsPlaying = state == .playing || state == .loading
            isBuffering = state == .loading
            localClock = PlaybackClock(
                position: localClock.position(),
                duration: localClock.duration,
                rate: localPlaybackState == .playing && !isBuffering ? 1 : 0
            )
            // Initial queue loads have no separate queue-content event.
            // Adopt both automatic and paused loads so the displayed song
            // follows the authoritative queue before any later queue edit.
            if (state == .loading || state == .paused), radio == nil {
                refreshFromAudio(enrich: true)
            }
            if state == .playing { errorMessage = nil }
        case .progress(let currentTime, let duration, _, _):
            let now = ProcessInfo.processInfo.systemUptime
            let projected = localClock.position(at: now)
            guard now - lastProgressSample >= 2 || abs(projected - currentTime) >= 2 else {
                return
            }
            lastProgressSample = now
            localClock = PlaybackClock(
                position: currentTime,
                duration: duration,
                rate: localPlaybackState == .playing && !isBuffering ? 1 : 0,
                sampledAt: now
            )
        case .durationChanged(let duration, _):
            localClock = PlaybackClock(
                position: localClock.position(),
                duration: duration,
                rate: localPlaybackState == .playing && !isBuffering ? 1 : 0
            )
        case .bufferingChanged(let buffering, _):
            isBuffering = buffering
            localClock = PlaybackClock(
                position: localClock.position(),
                duration: localClock.duration,
                rate: localPlaybackState == .playing && !buffering ? 1 : 0
            )
        case .ended:
            localPlaybackState = .ended
            localIsPlaying = false
            isBuffering = false
            localClock = PlaybackClock(
                position: localClock.position(),
                duration: localClock.duration,
                rate: 0
            )
        case .error(_, let message, _):
            errorMessage = message
            isBuffering = false
        case .queueStateChanged, .queueContentsChanged:
            refreshFromAudio(enrich: true)
        case .systemVolumeChanged(let value):
            localVolume = Double(value)
        case .sleepTimerFired:
            sleepTimer = .off
        case .remoteCommand(let command, _):
            if command.lowercased().contains("like") {
                Task { @MainActor [weak self] in await self?.toggleFavoriteCurrent() }
            }
        case .interruptionChanged, .routeChanged, .downloadProgress,
            .downloadCompleted, .downloadFailed, .streamCacheCompleted,
            .bufferComplete, .recoveryAttempt:
            break
        }
    }

    private func refreshFromAudio(enrich: Bool) {
        refreshGeneration += 1
        let generation = refreshGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == self.refreshGeneration else { return }
            // The native snapshot already reads on the main thread. Adopt it
            // in the same actor turn so newer events cannot be overwritten
            // while a detached reader waits to return to the main actor.
            let playback = self.playbackSnapshot()
            self.adopt(playback, enrich: enrich)
        }
    }

    private func adopt(_ playback: AudioPlaybackSnapshot, enrich: Bool) {
        localPlaybackState = playback.state
        localIsPlaying = playback.state == .playing || playback.state == .loading
        isBuffering = playback.state == .loading
        localClock = PlaybackClock(
            position: playback.currentTime,
            duration: playback.duration,
            rate: localPlaybackState == .playing && !isBuffering ? 1 : 0
        )
        guard let snapshot = playback.queue else {
            lastSnapshot = nil
            if radio == nil {
                localSong = nil
                localQueue = .empty
                localShuffle = false
                localRepeatMode = .off
            }
            return
        }

        lastSnapshot = snapshot
        radio = nil
        localShuffle = snapshot.isShuffleActive
        localRepeatMode = snapshot.loopState
        localQueue = Self.playerQueue(from: snapshot, songs: songCache)
        localSong = currentQueueSong(in: snapshot).map(song(from:))
        if let localSong, let favorites {
            audio.setLikeActive(favorites.isFavorite(.song, id: localSong.id))
        } else {
            audio.setLikeActive(false)
        }
        if enrich {
            enrichSongs(in: snapshot)
        }
    }

    /// Looks up the queue's songs that are neither cached nor already being
    /// looked up. Results from before the last `clearAll()` are dropped.
    private func enrichSongs(in snapshot: AudioQueueSnapshot) {
        let all = snapshot.contextSongs + snapshot.userQueue + snapshot.playedUserQueueHistory
        var seen = Set<String>()
        let ids = all.map(\.id).filter {
            songCache[$0] == nil
                && !enrichingSongIds.contains($0)
                && seen.insert($0).inserted
        }
        guard !ids.isEmpty else { return }
        enrichingSongIds.formUnion(ids)
        let generation = enrichmentGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let songs: [Song]
            do {
                songs = try await repository.songs(ids: ids)
            } catch {
                // The queue's compact song values remain usable offline.
                if generation == enrichmentGeneration {
                    enrichingSongIds.subtract(ids)
                }
                return
            }
            guard generation == enrichmentGeneration else { return }
            enrichingSongIds.subtract(ids)
            for song in songs { songCache[song.id] = song }
            guard let current = lastSnapshot else { return }
            localQueue = Self.playerQueue(from: current, songs: songCache)
            localSong = currentQueueSong(in: current).map(song(from:))
        }
    }

    static func playerQueue(
        from snapshot: AudioQueueSnapshot,
        songs: [String: Song] = [:]
    ) -> PlayerQueue {
        func value(_ item: QueueSong) -> Song {
            songs[item.id]
                ?? Song(
                    id: item.id,
                    title: item.title,
                    album: item.album,
                    albumId: item.albumId,
                    artist: item.artist,
                    artistId: item.artistId,
                    coverArt: item.coverArtId,
                    duration: Int(item.duration.rounded()),
                    replayGain: item.replayGain.map {
                        ReplayGainInfo(
                            trackGain: $0.trackGain,
                            trackPeak: $0.trackPeak,
                            albumGain: $0.albumGain,
                            albumPeak: $0.albumPeak
                        )
                    }
                )
        }

        let contextIndex = min(
            max(snapshot.currentIndex, 0), max(0, snapshot.contextSongs.count - 1))
        let historyEnd = min(
            snapshot.contextSongs.count,
            contextIndex + (snapshot.isInUserQueue ? 1 : 0)
        )
        let history = snapshot.contextSongs.prefix(historyEnd).enumerated().map {
            QueueEntry(song: value($0.element), tier: .context, index: $0.offset)
        }
        let current: QueueEntry? =
            if snapshot.isInUserQueue,
                let song = snapshot.userQueue.first
            {
                QueueEntry(song: value(song), tier: .user, index: 0)
            } else if snapshot.contextSongs.indices.contains(contextIndex) {
                QueueEntry(
                    song: value(snapshot.contextSongs[contextIndex]),
                    tier: .context,
                    index: contextIndex
                )
            } else {
                nil
            }
        let hiddenUserCount = snapshot.isInUserQueue ? 1 : 0
        let userQueue = snapshot.userQueue.dropFirst(hiddenUserCount).enumerated().map {
            QueueEntry(
                song: value($0.element),
                tier: .user,
                index: $0.offset + hiddenUserCount
            )
        }
        let upNext = snapshot.contextSongs.dropFirst(contextIndex + 1).enumerated().map {
            QueueEntry(
                song: value($0.element),
                tier: .context,
                index: $0.offset + contextIndex + 1
            )
        }
        let source = snapshot.sourceId.flatMap {
            QueueSource(encoded: "\($0.type):\($0.id)")
        }
        return PlayerQueue(
            history: history,
            current: current,
            userQueue: userQueue,
            upNext: upNext,
            source: source,
            sourceName: snapshot.sourceName
        )
    }

    private func currentQueueSong(in snapshot: AudioQueueSnapshot) -> QueueSong? {
        if snapshot.isInUserQueue { return snapshot.userQueue.first }
        guard snapshot.contextSongs.indices.contains(snapshot.currentIndex) else { return nil }
        return snapshot.contextSongs[snapshot.currentIndex]
    }

    private func song(from item: QueueSong) -> Song {
        songCache[item.id] ?? Self.playerQueueSong(item)
    }

    private static func playerQueueSong(_ item: QueueSong) -> Song {
        Song(
            id: item.id,
            title: item.title,
            album: item.album,
            albumId: item.albumId,
            artist: item.artist,
            artistId: item.artistId,
            coverArt: item.coverArtId,
            duration: Int(item.duration.rounded()),
            replayGain: item.replayGain.map {
                ReplayGainInfo(
                    trackGain: $0.trackGain,
                    trackPeak: $0.trackPeak,
                    albumGain: $0.albumGain,
                    albumPeak: $0.albumPeak
                )
            }
        )
    }

    private func queueSongs(from songs: [Song]) -> [QueueSong] {
        songs.compactMap(queueSong(from:))
    }

    private func queueSong(from song: Song) -> QueueSong? {
        guard !song.id.isEmpty else { return nil }
        songCache[song.id] = song
        let tags = song.replayGain.map {
            AudioReplayGain(
                trackGain: $0.trackGain,
                trackPeak: $0.trackPeak,
                albumGain: $0.albumGain,
                albumPeak: $0.albumPeak
            )
        }
        let coverArt = settings.settings.playback.useAlbumCoverForSongs
            ? (song.albumId ?? song.coverArt)
            : song.coverArt
        return QueueSong(
            id: song.id,
            title: song.title,
            artist: song.artistLine,
            artistId: song.artistId,
            album: song.album,
            albumId: song.albumId,
            duration: Double(song.duration),
            coverArtId: coverArt,
            streamUrl: LibraryMediaReference(songID: song.id).urlString,
            replayGain: tags
        )
    }

    private func startLocalPlayback(
        songs: [Song],
        index: Int,
        shuffle: Bool,
        source: QueueSource?,
        sourceName: String?
    ) {
        let converted = songs.enumerated().compactMap { offset, song in
            queueSong(from: song).map { (offset, $0) }
        }
        let original = converted.map(\.1)
        guard let convertedIndex = converted.firstIndex(where: { $0.0 == index }) else {
            errorMessage = "Unable to build a stream URL for this song."
            return
        }

        var queue = original
        var queueIndex = convertedIndex
        if shuffle {
            let ordered: [QueueSong]
            if localRepeatMode == .all {
                ordered = Array(original[convertedIndex...]) + Array(original[..<convertedIndex])
            } else {
                ordered = Array(original[convertedIndex...])
            }
            if let first = ordered.first {
                queue = [first] + ordered.dropFirst().shuffled()
                queueIndex = 0
            }
        }
        let nativeSource = source.map { AudioQueueSource(type: $0.kind.rawValue, id: $0.id) }
        radio = nil
        errorMessage = nil
        audio.setContextQueue(
            songs: queue,
            currentIndex: queueIndex,
            sourceId: nativeSource,
            sourceName: sourceName,
            autoplay: true,
            repeatMode: localRepeatMode
        )
        if shuffle { audio.markAsShuffled(originalSongs: original) }
        playbackStarts += 1
    }

    private func randomShuffleStartIndex(for songs: [Song]) -> Int {
        let history = target.isRemote ? [] : (lastSnapshot?.shuffleStartHistory ?? [])
        return NativeShuffleEngine().pickRandomStartIndex(
            count: songs.count,
            startHistory: history,
            getId: { songs[$0].id }
        )
    }

    private func isSameContext(songs: [Song], index: Int, source: QueueSource?) -> Bool {
        guard !isShuffleActive,
            queue.current?.tier == .context,
            queue.current?.song.id == songs[index].id,
            queue.source == source
        else { return false }
        let active = ([queue.current].compactMap { $0 } + queue.upNext).map(\.song.id)
        return active == Array(songs[index...]).map(\.id)
    }

    private func sendRemotePlayback(
        songs: [Song],
        index: Int,
        shuffle: Bool,
        source: QueueSource?
    ) {
        sendRemoteSequence(
            remotePlaybackCommands(
                songs: songs,
                index: index,
                shuffle: shuffle,
                source: source
            ))
    }

    private func remotePlaybackCommands(
        songs: [Song],
        index: Int,
        shuffle: Bool,
        source: QueueSource?
    ) -> [CoordinationRemoteCommand] {
        let command: CoordinationRemoteCommand
        switch source?.kind {
        case .album:
            command = .playAlbum(albumId: source?.id ?? "", index: index, shuffle: shuffle)
        case .playlist:
            command = .playPlaylist(playlistId: source?.id ?? "", index: index, shuffle: shuffle)
        default:
            command = .playAtIndex(songIds: songs.map(\.id), index: index)
        }
        return shuffle && source?.kind != .album && source?.kind != .playlist
            ? [command, .setShuffle(true)]
            : [command]
    }

    private func sendRemote(_ command: CoordinationRemoteCommand) {
        sendRemoteSequence([command])
    }

    private func sendRemoteSequence(_ commands: [CoordinationRemoteCommand]) {
        guard let remote else { return }
        Task { @MainActor [weak self, weak remote] in
            guard let self, let remote else { return }
            do {
                for command in commands { try await remote.send(command) }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func enqueueAndStart(_ songs: [Song]) {
        if target.isRemote {
            sendRemoteSequence([
                .addToQueueNext(songIds: songs.map(\.id)),
                .next,
            ])
            return
        }
        let converted = queueSongs(from: songs)
        guard !converted.isEmpty else { return }
        audio.addToUserQueue(songs: converted, position: "next")
        audio.skipToNext()
    }

    private func reorder<Element>(
        _ values: inout [Element],
        from source: IndexSet,
        to destination: Int
    ) {
        let valid = source.filter { values.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return }
        let moved = valid.map { values[$0] }
        for index in valid.reversed() { values.remove(at: index) }
        let removedBefore = valid.filter { $0 < destination }.count
        let insertion = min(max(0, destination - removedBefore), values.count)
        values.insert(contentsOf: moved, at: insertion)
    }
}
