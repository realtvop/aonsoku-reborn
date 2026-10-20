import AonsokuKit
import SwiftUI

@main
struct AonsokuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel
    @State private var router = Router()

    init() {
        // Loads settings and the stored session before the first frame, so
        // launch shows the right screen without a placeholder.
        let app = AppModel()
        app.start()
        _app = State(initialValue: app)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot(app: app, router: router)
        }
        .onChange(of: scenePhase) { _, phase in
            let lifecycle = AppServices.shared.lifecycle
            switch phase {
            case .background:
                lifecycle.didEnterBackground()
            case .active:
                // Moves background -> foreground -> active; repeated
                // activations are ignored by the lifecycle gate.
                lifecycle.didBecomeActive()
                app.didBecomeActive()
            default:
                break
            }
        }
    }
}

/// The window content, inside the app environment. The environment is
/// applied last so the theme and toast modifiers can read the stores, and
/// in a view body so a language change re-renders it.
private struct AppRoot: View {
    let app: AppModel
    let router: Router

    var body: some View {
        RootView()
            .themeRoot()
            .toastHost(app)
            .shakeToOpenDebugPanel()
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                app.didReceiveMemoryWarning()
            }
            .appEnvironment(app, router: router)
    }
}
