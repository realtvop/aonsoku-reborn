import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A transition of the host application between being used and not.
enum ApplicationLifecycleEvent: Equatable, Sendable {
    /// iOS: the app entered the background. macOS: the app resigned active.
    case didEnterBackground
    /// iOS: the app will enter the foreground. macOS: the app became active.
    case willEnterForeground
}

/// Source of `ApplicationLifecycleEvent`s. Injected so schedulers can be driven
/// without a running `UIApplication`/`NSApplication`.
protocol ApplicationLifecycleObserving: Sendable {
    /// Calls `handler` on the thread that posts the transition (the main
    /// thread for both system applications) until the token is cancelled.
    func observe(
        _ handler: @escaping @Sendable (ApplicationLifecycleEvent) -> Void
    ) -> ObservationToken
}

/// Observes the system application's notifications.
struct SystemApplicationLifecycle: ApplicationLifecycleObserving {
    private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    /// The notification each event is derived from. Referencing these names
    /// does not create `NSApplication.shared`, so headless tests may use them.
    static var notificationNames: (
        background: Notification.Name,
        foreground: Notification.Name
    ) {
        #if canImport(UIKit)
        (UIApplication.didEnterBackgroundNotification,
         UIApplication.willEnterForegroundNotification)
        #else
        (NSApplication.didResignActiveNotification,
         NSApplication.didBecomeActiveNotification)
        #endif
    }

    func observe(
        _ handler: @escaping @Sendable (ApplicationLifecycleEvent) -> Void
    ) -> ObservationToken {
        let names = Self.notificationNames
        let center = self.center
        let background = center.addObserver(
            forName: names.background, object: nil, queue: nil
        ) { _ in handler(.didEnterBackground) }
        let foreground = center.addObserver(
            forName: names.foreground, object: nil, queue: nil
        ) { _ in handler(.willEnterForeground) }
        return ObservationToken {
            center.removeObserver(background)
            center.removeObserver(foreground)
        }
    }
}

/// Process-level facts about the host application.
enum PlatformApplication {
    /// Whether the process is running in the background right now. Only the
    /// main thread can ask `UIApplication`, so other threads report `false`.
    ///
    /// iOS suspends backgrounded processes and may close their sockets. A Mac
    /// app keeps running (and playing) while another app is frontmost, so it is
    /// never treated as backgrounded here; its lifecycle owner reports
    /// transitions explicitly through `AppLifecycleService`.
    static var isInBackground: Bool {
        #if canImport(UIKit)
        Thread.isMainThread
            ? UIApplication.shared.applicationState == .background
            : false
        #else
        false
        #endif
    }
}
