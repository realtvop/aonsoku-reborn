import AVFoundation
import Foundation

/// Why the audio output changed, named after `AVAudioSession.RouteChangeReason`.
/// The raw values are the strings `AudioServiceEvent.routeChanged` carries.
enum AudioRouteChangeReason: String, Equatable, Sendable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
}

enum AudioInterruptionEvent: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

/// The notifications an audio session posts. Handlers run on the main queue
/// until the returned token is cancelled or released.
protocol AudioSessionEventSource: AnyObject {
    func observeInterruptions(
        _ handler: @escaping @Sendable (AudioInterruptionEvent) -> Void
    ) -> ObservationToken

    func observeRouteChanges(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) -> ObservationToken
}

/// The system audio session `AudioService` plays through: `AVAudioSession` on
/// iOS, and on macOS (which has no audio session) a stand-in that watches the
/// default output device.
protocol PlaybackAudioSession: AudioSessionEventSource {
    /// Declares that the app plays audio.
    func configure() throws
    /// Takes audio focus before playback starts.
    func activate() throws
    func deactivate()

    /// Whether playback must pause itself when the output device it was using
    /// goes away. iOS pauses `AVPlayer` on its own; macOS does not.
    var pausesWhenOutputDisappears: Bool { get }
}

enum PlatformAudio {
    static func makeSession() -> PlaybackAudioSession {
        SystemAudioSession()
    }

    static func makeVolumeControl() -> OutputVolumeControlling {
        #if canImport(UIKit)
        SystemVolumeControl()
        #else
        AppVolumeControl()
        #endif
    }
}

#if canImport(UIKit)

final class SystemAudioSession: PlaybackAudioSession {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    var pausesWhenOutputDisappears: Bool { false }

    func configure() throws {
        try session.setCategory(.playback, mode: .default)
    }

    func activate() throws {
        try session.setActive(true)
    }

    func deactivate() {
        try? session.setActive(false)
    }

    func observeInterruptions(
        _ handler: @escaping @Sendable (AudioInterruptionEvent) -> Void
    ) -> ObservationToken {
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { notification in
            guard let event = Self.interruption(from: notification) else { return }
            handler(event)
        }
        return ObservationToken { center.removeObserver(observer) }
    }

    func observeRouteChanges(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) -> ObservationToken {
        let center = NotificationCenter.default
        let observer = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { notification in
            handler(Self.routeChangeReason(from: notification))
        }
        return ObservationToken { center.removeObserver(observer) }
    }

    static func interruption(from notification: Notification) -> AudioInterruptionEvent? {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
            as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            return .began
        case .ended:
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey]
                as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(
                rawValue: optionsRaw
            ).contains(.shouldResume)
            return .ended(shouldResume: shouldResume)
        @unknown default:
            return nil
        }
    }

    static func routeChangeReason(from notification: Notification) -> AudioRouteChangeReason {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
            as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
            return .unknown
        }
        switch reason {
        case .unknown: return .unknown
        case .newDeviceAvailable: return .newDeviceAvailable
        case .oldDeviceUnavailable: return .oldDeviceUnavailable
        case .categoryChange: return .categoryChange
        case .override: return .override
        case .wakeFromSleep: return .wakeFromSleep
        case .noSuitableRouteForCategory: return .noSuitableRouteForCategory
        case .routeConfigurationChange: return .routeConfigurationChange
        @unknown default: return .unknown
        }
    }
}

#else

/// macOS has no audio session to configure, activate or interrupt, and
/// `AVPlayer` keeps playing when headphones are unplugged. This watches the
/// default output device and reports the routes it loses and gains, so
/// `AudioService` can pause the way the iOS system does.
final class SystemAudioSession: PlaybackAudioSession {
    private let outputSource: AudioOutputSnapshotSource

    init(outputSource: AudioOutputSnapshotSource = PlatformAudioOutput.makeSource()) {
        self.outputSource = outputSource
    }

    var pausesWhenOutputDisappears: Bool { true }

    func configure() throws {}
    func activate() throws {}
    func deactivate() {}

    func observeInterruptions(
        _ handler: @escaping @Sendable (AudioInterruptionEvent) -> Void
    ) -> ObservationToken {
        // Nothing interrupts playback on macOS.
        ObservationToken {}
    }

    func observeRouteChanges(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) -> ObservationToken {
        AudioRouteMonitor(source: outputSource).start(handler)
    }
}

#endif
