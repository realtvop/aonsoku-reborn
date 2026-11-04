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
    @State private var app: AppModel
    @State private var router: Router
    @StateObject private var commandState: MacCommandState

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
        _commandState = StateObject(wrappedValue: MacCommandState(app: model, router: router))
        MacAppDelegate.app = model
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
        .commands {
            MacCommands(app: app, router: router, state: commandState)
        }

        Settings {
            MacSceneRoot(app: app, router: router) {
                MacSettingsView()
            }
        }

        Window(app.localizer("native.mac.debug.title"), id: MacWindowID.debug) {
            MacSceneRoot(app: app, router: router) {
                MacDebugView()
            }
        }
        .defaultSize(width: 760, height: 560)
    }
}

/// Window identifiers shared by the scenes, the commands, the app delegate
/// and the DEBUG snapshot driver.
enum MacWindowID {
    static let main = "main"
    static let debug = "debug"
}

/// The main window's content, inside the app environment. The environment
/// is applied last so the theme and toast modifiers can read the stores, and
/// in a view body so a language change re-renders it.
private struct MacAppRoot: View {
    let app: AppModel
    let router: Router

    @Environment(\.openWindow) private var openWindow

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
                .onAppear {
                    // The Dock brings the window back after it was closed.
                    MacAppDelegate.openMainWindow = { openWindow(id: MacWindowID.main) }
                }
                .appEnvironment(app, router: router)
        }
    }
}

/// The content of the Settings and Debug windows, in the same environment
/// and theme as the main window.
private struct MacSceneRoot<Content: View>: View {
    let app: AppModel
    let router: Router
    @ViewBuilder let content: Content

    var body: some View {
        WithPerceptionTracking {
            content
                .themeRoot()
                .appEnvironment(app, router: router)
        }
    }
}

/// Process-level hooks SwiftUI does not expose on macOS. Closing the window
/// neither stops playback nor quits; the Dock icon brings the window back
/// and its menu has the transport. Activation reaches `AppLifecycleService`
/// without the background semantics of iOS: a Mac app keeps playing and
/// drawing while another app is in front, so resigning only saves the
/// playback state, and termination flushes it.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// The app's model, for the Dock menu, activation and key routing.
    static var app: AppModel?
    /// Opens (or brings forward) the main window.
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SyncScheduler.register()
        if let player = Self.app?.player {
            MacKeyRouting.install(player: player)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let openMainWindow = Self.openMainWindow else { return true }
        openMainWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppServices.shared.lifecycle.didBecomeActive()
        Self.app?.didBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        AppServices.shared.lifecycle.didResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.lifecycle.willTerminate()
    }

    /// What plays, Play/Pause, Next, Previous and Like.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let app = Self.app, app.player.hasMedia else { return nil }
        let t = app.localizer
        let player = app.player
        let menu = NSMenu()
        let nowPlaying = NSMenuItem(title: NowPlayingText.title(player, t), action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)
        if let subtitle = NowPlayingText.subtitle(player, t) {
            let item = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item(t(player.isPlaying ? "player.tooltips.pause" : "player.tooltips.play"), #selector(togglePlayPause)))
        menu.addItem(item(t("player.tooltips.next"), #selector(next)))
        menu.addItem(item(t("player.tooltips.previous"), #selector(previous)))
        if let song = player.currentSong {
            menu.addItem(.separator())
            let isFavorite = app.favorites.isFavorite(.song, id: song.id)
            menu.addItem(item(t(isFavorite ? "options.unlike" : "options.like"), #selector(toggleLike)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePlayPause() { Self.app?.player.togglePlayPause() }
    @objc private func next() { Self.app?.player.next() }
    @objc private func previous() { Self.app?.player.previous() }
    @objc private func toggleLike() {
        guard let player = Self.app?.player else { return }
        Task { await player.toggleFavoriteCurrent() }
    }
}
