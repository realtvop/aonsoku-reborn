#if DEBUG
import AonsokuKit
import AppKit
import SwiftUI

/// A DEBUG-only way to look at the Mac app without a screen: launched with
/// `--snapshot-dir <dir>`, it signs in to a test server when asked, walks
/// through a script of scenes and writes each window as a PNG, with a text
/// dump of its accessibility tree and of the menu bar, then quits.
///
/// The sandbox only lets the app write inside its container, so a relative
/// `<dir>` is resolved against the container's temporary directory, and the
/// path used is printed on standard output.
///
///     Aonsoku.app/Contents/MacOS/Aonsoku --snapshot-dir shots \
///       --snapshot-server http://127.0.0.1:47533 --snapshot-user qa \
///       --snapshot-password qa [--snapshot-scenes home,album] [--snapshot-keep-session]
@MainActor
final class MacSnapshotDriver {
    struct Options {
        var directory: URL
        var server: String?
        var username = "qa"
        var password = "qa"
        var scenes: Set<String>?
        var keepsSession = false
        /// Brings the app to the front, so windows draw as key: prominent
        /// buttons and selections lose their accent color in inactive
        /// windows. Off by default, since it takes focus from the user.
        var activates = false
        var size = CGSize(width: 1280, height: 820)
    }

    /// A step of the script: something to do, how long to let it settle,
    /// and whether to capture the windows afterwards.
    struct Scene {
        let name: String
        var settle: Duration = .milliseconds(1500)
        var captures = true
        let prepare: @MainActor (MacSnapshotDriver) async -> Void
    }

    static var options: Options? = {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--snapshot-dir") else { return nil }
        let directory = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent(path, isDirectory: true)
        var options = Options(directory: directory)
        options.server = value("--snapshot-server")
        options.username = value("--snapshot-user") ?? options.username
        options.password = value("--snapshot-password") ?? options.password
        options.scenes = value("--snapshot-scenes").map { Set($0.split(separator: ",").map(String.init)) }
        options.keepsSession = arguments.contains("--snapshot-keep-session")
        options.activates = arguments.contains("--snapshot-activate")
        return options
    }()

    let options: Options
    let app: AppModel
    let router: Router
    private var report: [String] = []
    private var index = 0

    init(options: Options, app: AppModel, router: Router) {
        self.options = options
        self.app = app
        self.router = router
    }

    /// Starts the script once the main window exists. Call once at launch.
    static func startIfRequested(app: AppModel, router: Router) {
        guard let options else { return }
        let driver = MacSnapshotDriver(options: options, app: app, router: router)
        Task { @MainActor in
            await driver.run()
            // Through the normal path, so the app delegate flushes state;
            // exit regardless when something holds termination up.
            NSApp.terminate(nil)
            try? await Task.sleep(for: .seconds(5))
            exit(0)
        }
    }

    // MARK: - Running

    private func run() async {
        try? FileManager.default.removeItem(at: options.directory)
        try? FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)
        note("dir \(options.directory.path)")
        guard await waitUntil(timeout: .seconds(20), { self.mainWindow != nil }) else {
            note("no main window")
            return finish()
        }
        configureMainWindow()
        // SwiftUI builds its accessibility elements only once an assistive
        // client asks for the enhanced interface, as VoiceOver does.
        _ = NSApp.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"),
            with: NSNumber(value: true), with: "AXEnhancedUserInterface"
        )
        _ = await waitUntil(timeout: .seconds(10)) { self.app.session.state != .restoring }

        for scene in MacSnapshotScript.scenes {
            guard options.scenes?.contains(scene.name) ?? true else { continue }
            note("scene \(scene.name)")
            await scene.prepare(self)
            try? await Task.sleep(for: scene.settle)
            if scene.captures { capture(scene.name) }
        }
        finish()
    }

    private func finish() {
        dumpMenus(to: "menus.txt")
        let text = report.joined(separator: "\n") + "\n"
        try? text.write(to: options.directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if !options.keepsSession, app.session.isSignedIn {
            app.signOut()
        }
        FileHandle.standardError.write(Data("snapshot-done: \(options.directory.path)\n".utf8))
    }

    func note(_ line: String) {
        report.append(line)
        FileHandle.standardError.write(Data("snapshot: \(line)\n".utf8))
    }

    // MARK: - Helpers for scenes

    /// Polls `condition` every 100 ms; returns whether it became true.
    @discardableResult
    func waitUntil(timeout: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MacWindowID.main) == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentViewController != nil }
    }

    /// Signs in to the test server unless a session is already active.
    func signInIfNeeded() async {
        guard !app.session.isSignedIn, let server = options.server else { return }
        do {
            try await app.signIn(
                serverUrl: server, fallbackUrl: nil,
                username: options.username, password: options.password
            )
            if app.isAwaitingAccountDecision {
                try app.confirmAccountSwitch()
            }
        } catch {
            note("sign-in failed: \(error)")
        }
        await waitUntil(timeout: .seconds(10)) { self.app.session.isSignedIn }
    }

    /// Waits for the first library sync to settle.
    func waitForSync() async {
        await waitUntil(timeout: .seconds(4)) { self.app.sync.isSyncing }
        let finished = await waitUntil(timeout: .seconds(60)) { !self.app.sync.isSyncing }
        note("sync finished=\(finished) phase=\(app.sync.phase)")
    }

    /// Presses a key in the key window, as typed: through the event
    /// monitors, the menu bar's key equivalents and the responder chain.
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = mainWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// The window's toolbar search field.
    func searchField(in window: NSWindow) -> NSSearchField? {
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for subview in view.subviews {
                if let field = find(subview) { return field }
            }
            return nil
        }
        return (window.contentView?.superview).flatMap(find)
    }

    /// Chooses the menu bar item titled `title`, as a click would.
    @discardableResult
    func performMenuItem(titled title: String) -> Bool {
        func find(in menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.title == title { return (menu, index) }
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let (menu, index) = find(in: main) else {
            note("no menu item \(title)")
            return false
        }
        menu.update()
        menu.performActionForItem(at: index)
        return true
    }

    /// Notes each visible window's identifier and title.
    func noteWindows(_ label: String) {
        let windows = NSApp.windows.filter(\.isVisible).map { "\($0.identifier?.rawValue ?? "-") \"\($0.title)\"" }
        note("\(label): \(windows)")
    }

    /// Notes the selected section's pages and Forward pages.
    func notePath() {
        let path = router.sectionPath.wrappedValue.map { "\($0)".prefix(40) }
        note("section \(router.section.storageKey) path \(path) back=\(router.canGoBack) forward=\(router.canGoForward)")
    }

    /// Notes what the player shows.
    func notePlayer() {
        let player = app.player
        let song = player.currentSong.map { "\($0.title) / \($0.artist)" } ?? "none"
        let clock = player.clock
        note(
            "player song=\(song) playing=\(player.isPlaying) radio=\(player.isRadio) "
                + "pos=\(Int(clock.position()))/\(Int(clock.duration)) shuffle=\(player.isShuffleActive) "
                + "repeat=\(player.repeatMode) volume=\(player.volume) upcoming=\(player.queue.upNext.count)"
        )
    }

    /// Notes the app's windows from front to back.
    func noteWindowOrder() {
        let numbers = NSWindow.windowNumbers(options: []) ?? []
        let windows = numbers.compactMap { NSApp.window(withWindowNumber: $0.intValue) }
        let order = windows.filter(\.isVisible).map { window in
            let kind = window.sheetParent != nil ? "sheet" : (window is NSPanel ? "panel" : "window")
            return "\(kind)(\(window.title.isEmpty ? "-" : window.title), level \(window.level.rawValue))"
        }
        note("windows front to back: \(order.joined(separator: ", "))")
        let levels = NSApp.windows.filter(\.isVisible).map { window in
            let kind = window.sheetParent != nil ? "sheet" : (window is NSPanel ? "panel" : "window")
            return "\(kind) level \(window.level.rawValue)"
        }
        note("visible window levels: \(levels.joined(separator: ", "))")
    }

    // MARK: - Capture

    private func configureMainWindow() {
        guard let window = mainWindow else { return }
        var frame = window.frame
        frame.size = options.size
        window.setFrame(frame, display: true)
        if options.activates {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Writes every visible window, at 1x, with its accessibility tree.
    func capture(_ name: String) {
        index += 1
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 40 && $0.frame.height > 40 }
        for (offset, window) in windows.enumerated() {
            let stem = String(format: "%02d-%@%@", index, name, offset == 0 ? "" : "-w\(offset)")
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: options.directory.appendingPathComponent("\(stem).png"))
            }
            var lines: [String] = ["window \(window.title) \(Int(window.frame.width))x\(Int(window.frame.height))"]
            // SwiftUI builds its elements when asked, under the content view.
            if let content = window.contentView {
                dumpAccessibility(content, depth: 0, into: &lines)
            }
            for child in window.accessibilityChildren() ?? [] where (child as AnyObject) !== window.contentView {
                dumpAccessibility(child, depth: 0, into: &lines)
            }
            try? (lines.joined(separator: "\n") + "\n")
                .write(to: options.directory.appendingPathComponent("\(stem).ax.txt"), atomically: true, encoding: .utf8)
            let unlabeled = lines.filter { $0.contains("UNLABELED") }
            note("captured \(stem) (\(unlabeled.count) unlabeled controls)")
        }
    }

    private func dumpAccessibility(_ element: Any, depth: Int, into lines: inout [String]) {
        guard depth < 40, let node = element as? NSAccessibilityProtocol else { return }
        let role = node.accessibilityRole()?.rawValue ?? "?"
        let label = node.accessibilityLabel() ?? ""
        let title = node.accessibilityTitle() ?? ""
        let value = (node.accessibilityValue() as? String) ?? ""
        let interesting: Set<String> = [
            "AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXRadioButton",
            "AXTextField", "AXLink", "AXIncrementor", "AXDisclosureTriangle", "AXSegmentedControl",
        ]
        let isControl = interesting.contains(role)
        var flag = ""
        if isControl, label.isEmpty, title.isEmpty {
            // Where it is and what else it says, to find it on the PNG.
            let frame = node.accessibilityFrame()
            let help = node.accessibilityHelp() ?? ""
            let identifier = node.accessibilityIdentifier() ?? ""
            flag = " UNLABELED at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
                + (help.isEmpty ? "" : " help=\(help)") + (identifier.isEmpty ? "" : " id=\(identifier)")
        }
        if isControl || !label.isEmpty || !title.isEmpty || role == "AXStaticText" || role == "AXRow" {
            let text = [label, title, value].filter { !$0.isEmpty }.joined(separator: " | ")
            lines.append(String(repeating: "  ", count: depth) + "\(role) \(text)\(flag)")
        }
        for child in node.accessibilityChildren() ?? [] {
            dumpAccessibility(child, depth: depth + 1, into: &lines)
        }
    }

    func dumpMenus(to name: String) {
        guard let menu = NSApp.mainMenu else { return }
        var lines: [String] = []
        func walk(_ menu: NSMenu, depth: Int) {
            // As when the menu opens: SwiftUI fills its items then.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for item in menu.items {
                if item.isSeparatorItem {
                    lines.append(String(repeating: "  ", count: depth) + "—")
                    continue
                }
                var shortcut = ""
                if !item.keyEquivalent.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    shortcut = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                        + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                        + (item.keyEquivalent == " " ? "Space" : item.keyEquivalent)
                }
                let state = item.isEnabled ? "" : " (disabled)"
                let check = item.state == .on ? " ✓" : ""
                lines.append(String(repeating: "  ", count: depth) + item.title + (shortcut.isEmpty ? "" : "  [\(shortcut)]") + state + check)
                if let submenu = item.submenu { walk(submenu, depth: depth + 1) }
            }
        }
        walk(menu, depth: 0)
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: options.directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
#endif
