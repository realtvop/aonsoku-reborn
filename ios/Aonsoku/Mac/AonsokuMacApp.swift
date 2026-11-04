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
    @State private var router: Router

    init() {
        // Before any view asks for a heading font.
        BrandFont.registerBundledFonts()
        #if DEBUG
        if MacSnapshotDriver.options != nil {
            KeychainManager.debugServiceSuffix = "snapshot.\(UUID().uuidString)"
        }
        #endif
        let services = AppServices.shared
        services.lifecycle.didFinishLaunching()
        let model = AppModel(services: services)
        model.start()
        let router = Router(style: .sidebar)
        _app = State(initialValue: model)
        _router = State(initialValue: router)
        #if DEBUG
        MacSnapshotDriver.startIfRequested(app: model, router: router)
        #endif
    }

    var body: some Scene {
        Window("Aonsoku", id: MacWindowID.main) {
            MacAppRoot(app: app, router: router)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
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

/// Window identifiers shared by the scenes, the app delegate and the
/// DEBUG snapshot driver.
enum MacWindowID {
    static let main = "main"
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
                .frame(minWidth: 860, minHeight: 560)
                .themeRoot()
                .toastHost(app)
                .background {
                    HostWindowReader { window in
                        // Saved in the user's defaults, so the frame comes
                        // back even when the system does not restore windows.
                        if window.frameAutosaveName.isEmpty {
                            window.setFrameAutosaveName("AonsokuMainWindow")
                        }
                    }
                }
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
