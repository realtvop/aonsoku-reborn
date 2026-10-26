import AonsokuKit
import Perception
import SwiftUI
import UIKit

@main
struct AonsokuApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel
    @State private var router = Router()

    init() {
        let services = AppServices.shared
        services.lifecycle.didFinishLaunching()
        let model = AppModel(services: services)
        model.start()
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot(app: app, router: router)
        }
        .onChange(of: scenePhase) { phase in
            let lifecycle = app.services.lifecycle
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
        WithPerceptionTracking {
            RootView()
                .themeRoot()
                .toastHost(app)
                .shakeToOpenDebugPanel()
                .background {
                    WithPerceptionTracking {
                        SystemVolumeHost(
                            hidesSystemHUD: router.isNowPlayingPresented
                        )
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
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
}

/// Keeps the private `MPVolumeView` used by `AudioService` in a live window.
/// iOS only exposes output-volume writes through that view, and its presence
/// suppresses the system HUD while Now Playing shows Aonsoku's own control.
private struct SystemVolumeHost: UIViewRepresentable {
    let hidesSystemHUD: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        connect(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        connect(uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Void) {
        AppServices.shared.audio.setVolumeHUDEnabled(true)
    }

    private func connect(_ view: UIView) {
        let audio = AppServices.shared.audio
        audio.start(volumeHostView: view)
        audio.setVolumeHUDEnabled(!hidesSystemHUD)
    }
}
