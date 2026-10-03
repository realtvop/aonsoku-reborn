import UIKit
import Capacitor
import AonsokuNativePlugin

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private let services = AppServices.shared

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.applicationSupportsShakeToEdit = false
        SyncScheduler.register()
        services.lifecycle.didFinishLaunching()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        services.lifecycle.didEnterBackground()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        services.lifecycle.willEnterForeground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        services.lifecycle.didBecomeActive()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        services.lifecycle.willTerminate()
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

}
