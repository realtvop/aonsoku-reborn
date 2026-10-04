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

    init(
        start: @escaping () -> Void,
        didEnterBackground: @escaping () -> Void,
        willEnterForeground: @escaping () -> Void,
        willTerminate: @escaping () -> Void,
        handleBackgroundSession: @escaping (
            String,
            @escaping () -> Void
        ) -> Bool
    ) {
        self.start = start
        self.didEnterBackground = didEnterBackground
        self.willEnterForeground = willEnterForeground
        self.willTerminate = willTerminate
        self.handleBackgroundSession = handleBackgroundSession
    }

    init(audio: AudioService) {
        start = { audio.start() }
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

    static let live = CoordinationLifecycleActions(
        didEnterBackground: {
            AonsokuNativeCoordinationPlugin.applicationDidEnterBackground()
        },
        willEnterForeground: {
            AonsokuNativeCoordinationPlugin.applicationWillEnterForeground()
        },
        willTerminate: {
            AonsokuNativeCoordinationPlugin.applicationWillTerminate()
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
