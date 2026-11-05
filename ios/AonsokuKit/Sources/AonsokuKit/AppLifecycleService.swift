import Foundation

enum AppLifecyclePhase: Equatable {
    case launching
    case active
    case background
    case foreground
    case terminated
}

struct AppLifecycleTransitionGate {
    private(set) var phase: AppLifecyclePhase = .launching

    mutating func transition(to next: AppLifecyclePhase) -> Bool {
        let isAllowed = switch (phase, next) {
        case (.launching, .active),
             (.active, .background),
             (.foreground, .background),
             (.background, .foreground),
             (.foreground, .active):
            true
        case (_, .terminated) where phase != .terminated:
            true
        default:
            false
        }
        guard isAllowed else { return false }
        phase = next
        return true
    }
}

struct AudioLifecycleActions {
    let start: () -> Void
    let didEnterBackground: () -> Void
    let willEnterForeground: () -> Void
    let willTerminate: () -> Void
    let handleBackgroundSession: (String, @escaping () -> Void) -> Bool
    let didResignActive: () -> Void
    let willSleep: () -> Void
    let connectionMayHaveChanged: () -> Void

    init(
        start: @escaping () -> Void,
        didEnterBackground: @escaping () -> Void,
        willEnterForeground: @escaping () -> Void,
        willTerminate: @escaping () -> Void,
        handleBackgroundSession: @escaping (
            String,
            @escaping () -> Void
        ) -> Bool,
        didResignActive: @escaping () -> Void = {},
        willSleep: @escaping () -> Void = {},
        connectionMayHaveChanged: @escaping () -> Void = {}
    ) {
        self.start = start
        self.didEnterBackground = didEnterBackground
        self.willEnterForeground = willEnterForeground
        self.willTerminate = willTerminate
        self.handleBackgroundSession = handleBackgroundSession
        self.didResignActive = didResignActive
        self.willSleep = willSleep
        self.connectionMayHaveChanged = connectionMayHaveChanged
    }

    init(audio: AudioService) {
        start = { audio.start() }
        didResignActive = { audio.applicationDidResignActive() }
        willSleep = { audio.applicationWillSleep() }
        connectionMayHaveChanged = { audio.connectionMayHaveChanged() }
        didEnterBackground = { audio.applicationDidEnterBackground() }
        willEnterForeground = { audio.applicationWillEnterForeground() }
        willTerminate = { audio.applicationWillTerminate() }
        handleBackgroundSession = { identifier, completion in
            audio.handleEventsForBackgroundURLSession(
                identifier: identifier,
                completionHandler: completion
            )
        }
    }
}

struct CoordinationLifecycleActions {
    let didEnterBackground: () -> Void
    let willEnterForeground: () -> Void
    let willTerminate: () -> Void
    let connectionMayHaveChanged: () -> Void

    init(
        didEnterBackground: @escaping () -> Void,
        willEnterForeground: @escaping () -> Void,
        willTerminate: @escaping () -> Void,
        connectionMayHaveChanged: @escaping () -> Void = {}
    ) {
        self.didEnterBackground = didEnterBackground
        self.willEnterForeground = willEnterForeground
        self.willTerminate = willTerminate
        self.connectionMayHaveChanged = connectionMayHaveChanged
    }

    static let live = CoordinationLifecycleActions(
        didEnterBackground: {
            CoordinationService.shared.didEnterBackground()
        },
        willEnterForeground: {
            CoordinationService.shared.willEnterForeground()
        },
        willTerminate: {
            CoordinationService.shared.willTerminate()
        },
        connectionMayHaveChanged: {
            CoordinationService.shared.connectionMayHaveChanged()
        }
    )
}

public final class AppLifecycleService: @unchecked Sendable {
    private let audio: AudioLifecycleActions
    private let coordination: CoordinationLifecycleActions
    private let lock = NSLock()
    private var transitions = AppLifecycleTransitionGate()

    init(audio: AudioService) {
        self.audio = AudioLifecycleActions(audio: audio)
        self.coordination = .live
    }

    init(
        audio: AudioLifecycleActions,
        coordination: CoordinationLifecycleActions
    ) {
        self.audio = audio
        self.coordination = coordination
    }

    public func didFinishLaunching() {
        guard transition(to: .active) else { return }
        audio.start()
    }

    public func didEnterBackground() {
        guard transition(to: .background) else { return }
        audio.didEnterBackground()
        coordination.didEnterBackground()
    }

    public func willEnterForeground() {
        guard transition(to: .foreground) else { return }
        audio.willEnterForeground()
        coordination.willEnterForeground()
    }

    /// The app is no longer the active one but keeps running in front of
    /// the user, as a Mac app does while another app is frontmost. Saves the
    /// playback state without entering the background, which would stop the
    /// coordination heartbeat and the published playback state; ignored
    /// once the app is in the background or terminating.
    public func didResignActive() {
        guard phase == .active || phase == .foreground else { return }
        audio.didResignActive()
    }

    /// The machine is about to sleep (a Mac; iOS suspends the app through
    /// `didEnterBackground`). A laptop may never wake again, so playback
    /// state is written and pending scrobbles are sent now. Nothing else
    /// changes: the app is not leaving the foreground, and what sleep broke
    /// is dealt with by `connectionMayHaveChanged()` when the machine wakes.
    /// Ignored outside the active and foreground phases.
    public func systemWillSleep() {
        guard phase == .active || phase == .foreground else { return }
        audio.willSleep()
    }

    /// The machine woke or the network path changed, so the connections
    /// opened before may be dead without the system having said so: the
    /// current stream is recovered at once instead of after its backoff, the
    /// coordination socket is checked and replaced with a fresh ticket if it
    /// does not answer. Safe to call repeatedly; ignored outside the active
    /// and foreground phases, where the lifecycle transitions already do this.
    public func connectionMayHaveChanged() {
        guard phase == .active || phase == .foreground else { return }
        audio.connectionMayHaveChanged()
        coordination.connectionMayHaveChanged()
    }

    public func didBecomeActive() {
        let current = phase
        if current == .background {
            willEnterForeground()
        }
        _ = transition(to: .active)
    }

    public func willTerminate() {
        guard transition(to: .terminated) else { return }
        coordination.willTerminate()
        audio.willTerminate()
    }

    @discardableResult
    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        audio.handleBackgroundSession(identifier, completionHandler)
    }

    var phase: AppLifecyclePhase {
        lock.lock()
        defer { lock.unlock() }
        return transitions.phase
    }

    private func transition(to phase: AppLifecyclePhase) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return transitions.transition(to: phase)
    }
}
