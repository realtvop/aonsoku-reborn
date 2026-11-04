import AonsokuKit
import AppKit
import Observation
import Perception
import SwiftUI

/// What the menu bar's titles and enablement depend on, mirrored from the
/// stores. SwiftUI rebuilds `Commands` when an observed object changes, but
/// not when a Perceptible store read inside a menu does, so this reads the
/// stores under `withObservationTracking` and publishes a new snapshot after
/// each change.
@MainActor
final class MacCommandState: ObservableObject {
    struct Snapshot: Equatable {
        var hasMedia = false
        var isPlaying = false
        var isRadio = false
        var isShuffleActive = false
        var repeatMode = AudioRepeatMode.off
        var canSeek = false
        var hasSong = false
        var albumId: String?
        var isFavorite = false
        var sleepTimer = SleepTimerState.off
        var canGoBack = false
        var canGoForward = false
        var isNowPlayingPresented = false
        var isSignedIn = false
        var isSyncing = false
        var isOnline = false
        /// Retitles the menus when the language changes.
        var language = ""
    }

    @Published private(set) var snapshot = Snapshot()

    private let app: AppModel
    private let router: Router

    init(app: AppModel, router: Router) {
        self.app = app
        self.router = router
        observe()
    }

    private func observe() {
        // Perceptible stores use Observation itself on macOS 14 and later.
        let next = withObservationTracking {
            read()
        } onChange: {
            // Called before the change lands; read it on the next turn.
            Task { @MainActor in self.observe() }
        }
        if next != snapshot { snapshot = next }
    }

    private func read() -> Snapshot {
        let player = app.player
        let song = player.currentSong
        return Snapshot(
            hasMedia: player.hasMedia,
            isPlaying: player.isPlaying,
            isRadio: player.isRadio,
            isShuffleActive: player.isShuffleActive,
            repeatMode: player.repeatMode,
            canSeek: player.hasMedia && !player.isRadio && player.clock.duration > 0,
            hasSong: song != nil,
            albumId: song?.albumId,
            isFavorite: song.map { app.favorites.isFavorite(.song, id: $0.id) } ?? false,
            sleepTimer: player.sleepTimer,
            canGoBack: router.canGoBack,
            canGoForward: router.canGoForward,
            isNowPlayingPresented: router.isNowPlayingPresented,
            isSignedIn: app.session.isSignedIn,
            isSyncing: app.sync.isSyncing,
            isOnline: app.network.isOnline,
            language: app.localizer.language.code
        )
    }
}

/// The menu bar: File, Edit, View, Playback, Library and Help commands with
/// their shortcuts, titled through the Localizer, enabled from
/// `MacCommandState`. Space plays and pauses except while typing
/// (`MacKeyRouting`).
struct MacCommands: Commands {
    let app: AppModel
    let router: Router
    @ObservedObject var state: MacCommandState

    @AppStorage(MacInspectorPanel.storageKey) private var panel = MacInspectorPanel.lyrics
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        let now = state.snapshot
        let t = app.localizer
        SidebarCommands()
        ToolbarCommands()
        CommandGroup(replacing: .newItem) {
            Button(t("options.playlist.create")) {
                router.present(.createPlaylist(songs: []))
            }
            .keyboardShortcut("n")
            .disabled(!now.isSignedIn)
        }
        CommandGroup(after: .textEditing) {
            Button(t("sidebar.search")) {
                router.focusSearch()
            }
            .keyboardShortcut("f")
            .disabled(!now.isSignedIn)
        }
        CommandGroup(before: .sidebar) {
            viewItems(now, t)
        }
        CommandMenu(t("shortcuts.playback.label")) {
            playbackItems(now, t)
        }
        CommandMenu(t("sidebar.library")) {
            Button(t("settings.storage.sync.syncNow")) {
                app.sync.syncNow()
            }
            .keyboardShortcut("r")
            .disabled(!now.isSignedIn || now.isSyncing || !now.isOnline)
            if now.isSyncing {
                Button(t("settings.storage.sync.cancel")) {
                    app.sync.cancel()
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button(t("native.mac.menu.website")) {
                openURL(AppInfo.repositoryURL)
            }
            Divider()
            Button(t("native.mac.menu.debug")) {
                openWindow(id: MacWindowID.debug)
            }
        }
    }

    // MARK: View

    /// Now Playing and its panels, the current song's album, Back and Forward.
    @ViewBuilder
    private func viewItems(_ now: MacCommandState.Snapshot, _ t: Localizer) -> some View {
        Button(t(now.isNowPlayingPresented ? "native.mac.player.hideNowPlaying" : "native.mac.player.showNowPlaying")) {
            router.isNowPlayingPresented.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .control])
        .disabled(!now.hasMedia && !now.isNowPlayingPresented)
        Toggle(t("fullscreen.lyrics"), isOn: panelBinding(.lyrics, now))
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!now.hasMedia || now.isRadio)
        Toggle(t("fullscreen.queue"), isOn: panelBinding(.queue, now))
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(!now.hasMedia || now.isRadio)
        Button(t("native.mac.menu.goToCurrentSong")) {
            if let albumId = now.albumId {
                router.navigate(to: .album(id: albumId, preview: nil))
            }
        }
        .keyboardShortcut("l")
        .disabled(now.albumId == nil)
        Divider()
        Button(t("navigation.back")) {
            router.goBack()
        }
        .keyboardShortcut("[")
        .disabled(!now.canGoBack)
        Button(t("native.mac.navigation.forward")) {
            router.goForward()
        }
        .keyboardShortcut("]")
        .disabled(!now.canGoForward)
        Divider()
    }

    /// On while Now Playing shows `target`; switching it on shows it.
    private func panelBinding(_ target: MacInspectorPanel, _ now: MacCommandState.Snapshot) -> Binding<Bool> {
        Binding(
            get: { now.isNowPlayingPresented && panel == target },
            set: { isOn in
                if isOn {
                    panel = target
                    router.isNowPlayingPresented = true
                } else {
                    router.isNowPlayingPresented = false
                }
            }
        )
    }

    // MARK: Playback

    /// Play and pause, next and previous, seeking, volume, shuffle and
    /// repeat, the like and the sleep timer, for whatever device the player
    /// controls.
    @ViewBuilder
    private func playbackItems(_ now: MacCommandState.Snapshot, _ t: Localizer) -> some View {
        let player = app.player
        shortcutItem(.playPause, t(now.isPlaying ? "player.tooltips.pause" : "player.tooltips.play"), isEnabled: now.hasMedia)
        shortcutItem(.next, t("player.tooltips.next"), isEnabled: now.hasMedia)
        shortcutItem(.previous, t("player.tooltips.previous"), isEnabled: now.hasMedia)
        Divider()
        shortcutItem(.seekForward, t("native.mac.menu.seekForward"), isEnabled: now.canSeek)
        shortcutItem(.seekBackward, t("native.mac.menu.seekBackward"), isEnabled: now.canSeek)
        Divider()
        shortcutItem(.volumeUp, t("shortcuts.playback.raiseVolume"), isEnabled: true)
        shortcutItem(.volumeDown, t("shortcuts.playback.lowerVolume"), isEnabled: true)
        Divider()
        Toggle(t("shortcuts.playback.shuffle"), isOn: Binding(
            get: { now.isShuffleActive },
            set: { _ in player.toggleShuffle() }
        ))
        .disabled(!now.hasMedia || now.isRadio)
        Picker(t("shortcuts.playback.repeat"), selection: Binding(
            get: { now.repeatMode },
            set: { player.setRepeatMode($0) }
        )) {
            Text(t("native.mac.menu.repeatOff")).tag(AudioRepeatMode.off)
            Text(t("native.mac.menu.repeatAll")).tag(AudioRepeatMode.all)
            Text(t("native.mac.menu.repeatOne")).tag(AudioRepeatMode.one)
        }
        .disabled(!now.hasMedia || now.isRadio)
        Divider()
        Button(t(now.isFavorite ? "options.unlike" : "options.like")) {
            Task { await player.toggleFavoriteCurrent() }
        }
        .disabled(!now.hasSong)
        Menu(t("player.sleepTimer.title")) {
            ForEach(SleepTimerState.presetMinutes, id: \.self) { minutes in
                Button(t("player.sleepTimer.minutes", ["count": String(minutes)])) {
                    player.setSleepTimer(minutes: minutes)
                }
            }
            Toggle(t("player.sleepTimer.endOfTrack"), isOn: Binding(
                get: { now.sleepTimer == .endOfTrack },
                set: { $0 ? player.setSleepTimerEndOfTrack() : player.cancelSleepTimer() }
            ))
            if now.sleepTimer.isActive {
                Divider()
                Button(t("player.sleepTimer.cancel")) {
                    player.cancelSleepTimer()
                }
            }
        }
        .disabled(!now.hasMedia)
    }

    private func shortcutItem(_ shortcut: MacPlaybackShortcut, _ title: String, isEnabled: Bool) -> some View {
        Button(title) {
            shortcut.perform(app.player)
        }
        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        .disabled(!isEnabled)
    }
}

/// The Playback menu's keys. `MacKeyRouting` matches key presses against
/// them too, so they act at once whatever state the menu bar last showed,
/// and give way to a text field being edited.
enum MacPlaybackShortcut: CaseIterable {
    case playPause, next, previous, seekForward, seekBackward, volumeUp, volumeDown

    var key: KeyEquivalent {
        switch self {
        case .playPause: .space
        case .next, .seekForward: .rightArrow
        case .previous, .seekBackward: .leftArrow
        case .volumeUp: .upArrow
        case .volumeDown: .downArrow
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .playPause: []
        case .next, .previous, .volumeUp, .volumeDown: .command
        case .seekForward, .seekBackward: [.command, .option]
        }
    }

    private var keyCode: UInt16 {
        switch self {
        case .playPause: 49
        case .next, .seekForward: 124
        case .previous, .seekBackward: 123
        case .volumeUp: 126
        case .volumeDown: 125
        }
    }

    private var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        return flags
    }

    /// The shortcut a key press is, ignoring the flags arrow keys carry.
    static func matching(_ event: NSEvent) -> MacPlaybackShortcut? {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return allCases.first { $0.keyCode == event.keyCode && $0.eventModifiers == flags }
    }

    @MainActor
    func canPerform(_ player: PlayerStore) -> Bool {
        switch self {
        case .playPause, .next, .previous: player.hasMedia
        case .seekForward, .seekBackward: player.hasMedia && !player.isRadio && player.clock.duration > 0
        case .volumeUp, .volumeDown: true
        }
    }

    @MainActor
    func perform(_ player: PlayerStore) {
        switch self {
        case .playPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .seekForward: seek(player, by: 10)
        case .seekBackward: seek(player, by: -10)
        case .volumeUp: player.setVolume(min(player.volume + 0.1, 1))
        case .volumeDown: player.setVolume(max(player.volume - 0.1, 0))
        }
    }

    @MainActor
    private func seek(_ player: PlayerStore, by seconds: TimeInterval) {
        let clock = player.clock
        player.seek(to: min(max(clock.position() + seconds, 0), clock.duration))
    }
}

// MARK: - Keys shared with text editing

/// Routes the Playback shortcuts: while a text field is being edited, the
/// keys they share with text editing (Space, and Command with an arrow for
/// line, document and word moves) go to the text, past the menus' key
/// equivalents. Otherwise the shortcut acts on the player at once. Sheets
/// and panels keep Space for their own buttons.
@MainActor
enum MacKeyRouting {
    private static var monitor: Any?

    static func install(player: PlayerStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread, which owns the event.
            nonisolated(unsafe) let keyEvent = event
            let consumed = MainActor.assumeIsolated { route(keyEvent, player: player) }
            return consumed ? nil : event
        }
    }

    /// True when the event was delivered here and must go no further.
    private static func route(_ event: NSEvent, player: PlayerStore) -> Bool {
        guard let shortcut = MacPlaybackShortcut.matching(event) else { return false }
        if let window = event.window {
            if window.firstResponder is NSText {
                window.sendEvent(event)
                return true
            }
            let isModal = window.sheetParent != nil || window.attachedSheet != nil || window is NSPanel
            if shortcut == .playPause, isModal || !player.hasMedia {
                window.sendEvent(event)
                return true
            }
        }
        guard shortcut.canPerform(player) else { return false }
        shortcut.perform(player)
        return true
    }
}
