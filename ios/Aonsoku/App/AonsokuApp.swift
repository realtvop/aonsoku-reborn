import AonsokuKit
import SwiftUI

@main
struct AonsokuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .shakeToOpenDebugPanel()
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
            default:
                break
            }
        }
    }
}
