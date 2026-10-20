import Foundation
import Observation

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
    public func position(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
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
@Observable
public final class PlayerStore {
    // MARK: Local state

    /// The local song; read `currentSong` for the remote-aware value.
    public private(set) var localSong: Song?
    /// The local radio station, when radio is playing.
    public private(set) var radio: RadioPlayback?
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

    @ObservationIgnored public weak var remote: (any RemotePlaybackSource)?
    /// Toggles the current song's favorite (lock screen Like and the player
    /// heart). Set by the app model.
    @ObservationIgnored public weak var favorites: FavoritesStore?

    @ObservationIgnored public let audio: AudioService
    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public let authentication: AuthenticationService

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
    public func start() {}

    /// Stops playback and clears the queue and its saved state (sign-out).
    public func clearAll() {}

    // MARK: Starting playback

    /// Plays `songs` from `index`, replacing the context queue. When songs
    /// the user queued would be lost while playing, sets
    /// `pendingReplacement` instead, unless `confirmed` is true.
    public func play(
        _ songs: [Song],
        startingAt index: Int = 0,
        shuffle: Bool = false,
        source: QueueSource? = nil,
        sourceName: String? = nil,
        confirmed: Bool = false
    ) {}

    /// Plays one song on its own (search results, song links).
    public func play(song: Song, sourceName: String? = nil, confirmed: Bool = false) {}

    /// Loads the album and plays it.
    public func playAlbum(id: String, startingAt index: Int = 0, shuffle: Bool = false) async {}

    public func playPlaylist(id: String, startingAt index: Int = 0, shuffle: Bool = false) async {}

    /// Plays every song by the artist (web artist play button).
    public func playArtist(id: String, name: String, shuffle: Bool = false) async {}

    /// Plays `stations[index]`. Next and previous move between stations.
    public func playRadio(_ stations: [RadioStation], index: Int) {}

    /// Answers `pendingReplacement`.
    public func resolveReplacement(_ choice: QueueReplacementChoice) {}

    /// Play Next (`.next`) or Add to Queue (`.last`).
    public func enqueue(_ songs: [Song], position: QueueInsertPosition) {}

    // MARK: Transport

    public func togglePlayPause() {}
    public func resume() {}
    public func pause() {}
    public func next() {}
    /// Restarts the song after three seconds, otherwise goes back.
    public func previous() {}
    public func seek(to seconds: TimeInterval) {}
    public func toggleShuffle() {}
    /// Off, all, one, off.
    public func cycleRepeat() {}
    /// System volume 0...1 (local), or the controlled device's volume.
    public func setVolume(_ volume: Double) {}

    // MARK: Queue

    /// Jumps to a queue row.
    public func play(entry: QueueEntry) {}

    /// Plays a history song next and starts it (web history rows).
    public func playFromHistory(_ song: Song) {}

    public func remove(entries: [QueueEntry]) {}

    /// Reorders rows within one tier, using `List.onMove` offsets relative
    /// to that tier's rows as shown.
    public func move(in tier: QueueTier, from source: IndexSet, to destination: Int) {}

    /// Clears the songs the user queued and the rest of the context queue,
    /// keeping the current song.
    public func clearQueue() {}

    // MARK: Sleep timer

    public func setSleepTimer(minutes: Int) {}
    public func setSleepTimerEndOfTrack() {}
    public func cancelSleepTimer() {}

    // MARK: Favorites

    public func toggleFavoriteCurrent() async {}
}
