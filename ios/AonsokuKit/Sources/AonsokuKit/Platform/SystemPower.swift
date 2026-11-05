import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The machine going to sleep and coming back. A Mac app is not suspended
/// when the lid closes, so it learns about this from the system rather than
/// from a background/foreground transition, and every connection it opened
/// before may be dead when it wakes.
enum SystemPowerEvent: Equatable, Sendable {
    /// The machine is about to sleep. A laptop may never wake again (a flat
    /// battery), so this is the last chance to save state.
    case willSleep
    /// The machine woke. The network may not be back yet.
    case didWake
}

/// Source of `SystemPowerEvent`s. Injected so tests can drive them without
/// sleeping the machine.
protocol SystemPowerEventSource: Sendable {
    /// Calls `handler` on the thread that posts the event until the token is
    /// cancelled or released.
    func observe(
        _ handler: @escaping @Sendable (SystemPowerEvent) -> Void
    ) -> ObservationToken
}

/// Derives `SystemPowerEvent`s from notifications of a given center.
struct SystemPowerNotifications: SystemPowerEventSource {
    private let center: NotificationCenter
    private let willSleep: Notification.Name
    private let didWake: Notification.Name

    init(
        center: NotificationCenter,
        willSleep: Notification.Name,
        didWake: Notification.Name
    ) {
        self.center = center
        self.willSleep = willSleep
        self.didWake = didWake
    }

    func observe(
        _ handler: @escaping @Sendable (SystemPowerEvent) -> Void
    ) -> ObservationToken {
        let center = center
        let sleeping = center.addObserver(
            forName: willSleep, object: nil, queue: nil
        ) { _ in handler(.willSleep) }
        let waking = center.addObserver(
            forName: didWake, object: nil, queue: nil
        ) { _ in handler(.didWake) }
        return ObservationToken {
            center.removeObserver(sleeping)
            center.removeObserver(waking)
        }
    }
}

/// A source that reports nothing.
struct NoPowerEvents: SystemPowerEventSource {
    func observe(
        _ handler: @escaping @Sendable (SystemPowerEvent) -> Void
    ) -> ObservationToken {
        ObservationToken {}
    }
}

enum PlatformPower {
    /// Whether a change of network path is by itself a reason to check the
    /// connections opened before it. iOS suspends the app and checks them
    /// when it returns to the foreground, and leaves a path change in the
    /// foreground to the transports; a Mac app keeps running and playing
    /// through one, so nothing else would notice a dead socket or stream.
    static var reconnectsOnNetworkPathChange: Bool {
        #if canImport(UIKit)
        false
        #else
        true
        #endif
    }

    /// - Parameter isTestProcess: a Mac test host must not react to the
    ///   machine it runs on really sleeping.
    static func makeSource(
        isTestProcess: Bool = PlatformStorage.isRunningUnderXCTest
    ) -> SystemPowerEventSource {
        #if canImport(AppKit)
        if isTestProcess { return NoPowerEvents() }
        // `NSWorkspace` posts these to its own center, not the default one.
        return SystemPowerNotifications(
            center: NSWorkspace.shared.notificationCenter,
            willSleep: NSWorkspace.willSleepNotification,
            didWake: NSWorkspace.didWakeNotification
        )
        #else
        // iOS suspends the app and tells it with background and foreground
        // transitions, which `AppLifecycleService` already handles.
        return NoPowerEvents()
        #endif
    }
}
