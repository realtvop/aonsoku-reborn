import AonsokuKit
import UIKit

/// Owns the process-level hooks that SwiftUI does not expose: background
/// task registration, background URLSession relaunches, and termination.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private var services: AppServices { .shared }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SyncScheduler.register()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if !services.lifecycle.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        ) {
            completionHandler()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        services.lifecycle.willTerminate()
    }
}
