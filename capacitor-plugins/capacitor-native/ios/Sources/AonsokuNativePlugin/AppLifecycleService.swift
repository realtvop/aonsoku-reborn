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

public final class AppLifecycleService: @unchecked Sendable {
    private let audio: AudioService
    private let lock = NSLock()
    private var transitions = AppLifecycleTransitionGate()

    init(audio: AudioService) {
        self.audio = audio
    }

    public func didFinishLaunching() {
        guard transition(to: .active) else { return }
        audio.start()
    }

    public func didEnterBackground() {
        guard transition(to: .background) else { return }
        audio.applicationDidEnterBackground()
        AonsokuNativeCoordinationPlugin.applicationDidEnterBackground()
    }

    public func willEnterForeground() {
        guard transition(to: .foreground) else { return }
        audio.applicationWillEnterForeground()
        AonsokuNativeCoordinationPlugin.applicationWillEnterForeground()
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
        AonsokuNativeCoordinationPlugin.applicationWillTerminate()
        audio.applicationWillTerminate()
    }

    @discardableResult
    public func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        audio.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
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
