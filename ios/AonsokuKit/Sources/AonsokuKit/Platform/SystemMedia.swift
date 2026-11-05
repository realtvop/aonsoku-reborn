import Foundation
import MediaPlayer

// The system's media surface: what Control Center, the Lock Screen, a Mac's
// Now Playing menu and the media keys show and send.
//
// `AudioService` describes the song with `SystemNowPlayingInfo`, reports the
// state with `SystemPlaybackState` and receives `SystemMediaCommand`s; it
// never touches `MPNowPlayingInfoCenter` or `MPRemoteCommandCenter` itself.
// The real implementation lives at the end of this file, and tests substitute
// a recording one, so neither platform's behavior depends on the machine the
// tests run on.

/// A transport command that comes from outside the app: a media key, Control
/// Center, the Lock Screen, headphones or a car.
enum SystemMediaCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    /// The scrubber of the system's Now Playing surface, in seconds.
    case changePlaybackPosition(TimeInterval)
    case toggleLike
}

/// Whether the app took a command. The system may show a failure to the user.
enum SystemMediaCommandResult: Equatable, Sendable {
    case success
    case failed
}

/// Receives the system's commands. May run on any thread.
typealias SystemMediaCommandHandler =
    @Sendable (SystemMediaCommand) -> SystemMediaCommandResult

/// The state the system shows for the app, and routes the media keys by.
enum SystemPlaybackState: Equatable, Sendable {
    case playing
    case paused
    /// Nothing is loaded, so the app is not what the media keys control.
    case stopped
}

/// The song as the system's Now Playing surface shows it.
///
/// This is all the system is ever told: there is no URL in it, so credentials
/// cannot reach the system. Artwork is the decoded image.
struct SystemNowPlayingInfo {
    var title: String?
    var artist: String?
    var album: String?
    /// Seconds; nil or zero when unknown.
    var duration: TimeInterval?
    /// The position at the moment of publication. The system keeps counting
    /// from it while `rate` is not zero, so it has to be published again after
    /// a seek or a pause, and after anything that republishes the entry.
    var elapsed: TimeInterval
    /// 1 while audio is coming out, 0 while paused or still buffering.
    var rate: Double
    var artwork: PlatformImage?
}

/// What `AudioService` needs from the system's media surface.
protocol SystemMediaSession: AnyObject {
    /// Shows `info` and reports `state`. A nil `info` withdraws the entry.
    /// Called on the main thread.
    func publish(_ info: SystemNowPlayingInfo?, state: SystemPlaybackState)

    /// Starts delivering the system's media commands to `handler` until the
    /// returned token is cancelled or released. A second call does not stop
    /// the first; the caller owns the token.
    func startReceivingCommands(
        _ handler: @escaping SystemMediaCommandHandler
    ) -> ObservationToken

    /// Whether the Like command shows the current song as liked. Called on the
    /// main thread.
    func setLikeActive(_ active: Bool)
}

enum PlatformSystemMedia {
    /// - Parameter isTestProcess: a Mac test host must not claim the Now
    ///   Playing slot or the media keys from whatever the person is listening
    ///   to, so it gets a session that shows and receives nothing. The iOS
    ///   Simulator has a media center of its own, which tests may use.
    static func makeSession(
        isTestProcess: Bool = PlatformStorage.isRunningUnderXCTest
    ) -> SystemMediaSession {
        #if os(macOS)
        if isTestProcess { return DetachedSystemMedia() }
        // A Mac has no audio session to tell the system what plays, so the
        // state is reported explicitly, `.stopped` included.
        return MediaPlayerSystemMedia(reportsStoppedState: true)
        #else
        return MediaPlayerSystemMedia(reportsStoppedState: false)
        #endif
    }
}

/// A session that shows nothing and receives nothing.
final class DetachedSystemMedia: SystemMediaSession {
    func publish(_ info: SystemNowPlayingInfo?, state: SystemPlaybackState) {}

    func startReceivingCommands(
        _ handler: @escaping SystemMediaCommandHandler
    ) -> ObservationToken {
        ObservationToken {}
    }

    func setLikeActive(_ active: Bool) {}
}

/// `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, on iOS and macOS.
final class MediaPlayerSystemMedia: SystemMediaSession, @unchecked Sendable {
    private let reportsStoppedState: Bool
    /// The system object for the artwork last published, so republishing the
    /// entry (every seek and pause does) does not hand it a new image.
    private var publishedArtwork: (image: PlatformImage, item: MPMediaItemArtwork)?

    /// - Parameter reportsStoppedState: whether withdrawing the entry also
    ///   sets `playbackState` to `.stopped`. A Mac needs it, since the state
    ///   is what makes the system stop sending media keys to the app. iOS
    ///   follows its audio session, and keeps the state it always published.
    init(reportsStoppedState: Bool) {
        self.reportsStoppedState = reportsStoppedState
    }

    func publish(_ info: SystemNowPlayingInfo?, state: SystemPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            publishedArtwork = nil
            center.nowPlayingInfo = nil
            if reportsStoppedState { center.playbackState = .stopped }
            return
        }
        center.nowPlayingInfo = Self.dictionary(
            for: info,
            artwork: artwork(for: info.artwork)
        )
        // The state is what the system picks the app for the media keys by,
        // so it follows an entry that is already complete.
        center.playbackState = Self.playbackState(for: state)
    }

    func setLikeActive(_ active: Bool) {
        MPRemoteCommandCenter.shared().likeCommand.isActive = active
    }

    func startReceivingCommands(
        _ handler: @escaping SystemMediaCommandHandler
    ) -> ObservationToken {
        let center = MPRemoteCommandCenter.shared()
        var registrations: [(command: MPRemoteCommand, target: Any)] = []

        func add(
            _ command: MPRemoteCommand,
            _ translate: @escaping (MPRemoteCommandEvent) -> SystemMediaCommand?
        ) {
            command.isEnabled = true
            let target = command.addTarget { event in
                guard let translated = translate(event) else { return .commandFailed }
                return handler(translated) == .success ? .success : .commandFailed
            }
            registrations.append((command, target))
        }

        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .togglePlayPause }
        add(center.nextTrackCommand) { _ in .nextTrack }
        add(center.previousTrackCommand) { _ in .previousTrack }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map {
                .changePlaybackPosition($0.positionTime)
            }
        }
        add(center.likeCommand) { _ in .toggleLike }

        let registered = registrations
        return ObservationToken {
            for (command, target) in registered {
                command.removeTarget(target)
                // Nothing answers it any more, so the system should not offer it.
                command.isEnabled = false
            }
        }
    }

    // MARK: Translation

    static func playbackState(for state: SystemPlaybackState) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    /// The entry in the form the system takes. Empty text, an unknown
    /// duration and positions that are not numbers are left out or clamped;
    /// the system logs errors for them and may drop the whole entry.
    static func dictionary(
        for info: SystemNowPlayingInfo,
        artwork: MPMediaItemArtwork?
    ) -> [String: Any] {
        var entry: [String: Any] = [:]
        if let title = info.title, !title.isEmpty {
            entry[MPMediaItemPropertyTitle] = title
        }
        if let artist = info.artist, !artist.isEmpty {
            entry[MPMediaItemPropertyArtist] = artist
        }
        if let album = info.album, !album.isEmpty {
            entry[MPMediaItemPropertyAlbumTitle] = album
        }
        if let duration = info.duration, duration.isFinite, duration > 0 {
            entry[MPMediaItemPropertyPlaybackDuration] = duration
        }
        // Typed first: assigned straight into `[String: Any]`, the fallback 0
        // would be stored as an Int.
        let elapsed: Double = info.elapsed.isFinite ? max(0, info.elapsed) : 0
        let rate: Double = info.rate.isFinite ? max(0, info.rate) : 0
        entry[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        entry[MPNowPlayingInfoPropertyPlaybackRate] = rate
        entry[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0 as Double
        if let artwork {
            entry[MPMediaItemPropertyArtwork] = artwork
        }
        return entry
    }

    private func artwork(for image: PlatformImage?) -> MPMediaItemArtwork? {
        guard let image else {
            publishedArtwork = nil
            return nil
        }
        if let publishedArtwork, publishedArtwork.image === image {
            return publishedArtwork.item
        }
        let item = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        publishedArtwork = (image, item)
        return item
    }
}
