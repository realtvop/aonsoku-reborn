import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = AonsokuViewController()
        window?.makeKeyAndVisible()

        NotificationCenter.default.post(
            name: Notification.Name("CapacitorSceneWillConnect"),
            object: scene
        )
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            NotificationCenter.default.post(
                name: .capacitorOpenURL,
                object: ["url": context.url]
            )
            NotificationCenter.default.post(
                name: Notification.Name("CapacitorSceneOpenURLNotification"),
                object: scene,
                userInfo: ["url": context.url]
            )
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }
        NotificationCenter.default.post(
            name: .capacitorOpenUniversalLink,
            object: ["url": url]
        )
        NotificationCenter.default.post(
            name: Notification.Name(
                "CapacitorSceneOpenUniversalLinkNotification"
            ),
            object: scene,
            userInfo: ["url": url]
        )
    }
}
