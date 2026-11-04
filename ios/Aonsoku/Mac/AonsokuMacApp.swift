import AonsokuKit
import AppKit
import Perception
import SwiftUI

/// The macOS entry point. The iOS entry point (`AonsokuApp`) stays iOS-only;
/// both build the same `AppModel` over `AppServices.shared` and wrap the
/// shared screens in the same environment.
@main
struct AonsokuMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel
    @State private var router = Router()

    init() {
        // Before any view asks for a heading font.
        BrandFont.registerBundledFonts()
        let services = AppServices.shared
        services.lifecycle.didFinishLaunching()
        let model = AppModel(services: services)
        model.start()
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            MacAppRoot(app: app, router: router)
        }
        .defaultSize(width: 1100, height: 720)
        .onChange(of: scenePhase) { _, phase in
            // A Mac app keeps running and playing while another app is in
            // front or its windows are closed, so only activation is
            // forwarded; there is no suspended state to enter.
            if phase == .active {
                app.services.lifecycle.didBecomeActive()
                app.didBecomeActive()
            }
        }
    }
}

/// The window content, inside the app environment. The environment is
/// applied last so the theme and toast modifiers can read the stores, and
/// in a view body so a language change re-renders it.
private struct MacAppRoot: View {
    let app: AppModel
    let router: Router

    var body: some View {
        WithPerceptionTracking {
            RootView { MacMainView() }
                .themeRoot()
                .toastHost(app)
                .appEnvironment(app, router: router)
        }
    }
}

/// Process-level hooks SwiftUI does not expose on macOS.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SyncScheduler.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.lifecycle.willTerminate()
    }
}
