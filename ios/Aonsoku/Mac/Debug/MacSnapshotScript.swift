#if DEBUG
import AonsokuKit
import AppKit

/// The scenes a snapshot run walks through, in order. `--snapshot-scenes`
/// picks some of them; steps that only prepare state do not capture.
enum MacSnapshotScript {
    static let scenes: [MacSnapshotDriver.Scene] = [
        .init(name: "login", settle: .milliseconds(800)) { _ in },
        .init(name: "signin", captures: false) { driver in
            await driver.signInIfNeeded()
            await driver.waitForSync()
        },
        .init(name: "home", settle: .seconds(3)) { driver in
            driver.router.section = .home
        },
        .init(name: "albums") { driver in
            driver.router.section = .albums
        },
        .init(name: "artists") { driver in
            driver.router.section = .artists
        },
        .init(name: "songs") { driver in
            driver.router.section = .songs
        },
        .init(name: "playlists") { driver in
            driver.router.section = .playlists
        },
        .init(name: "playlist") { driver in
            driver.router.section = .playlist(id: "pl1")
        },
        .init(name: "favorites") { driver in
            driver.router.section = .favorites
        },
        .init(name: "genres") { driver in
            driver.router.section = .genres
        },
        .init(name: "search", settle: .seconds(2)) { driver in
            driver.router.section = .home
            driver.router.searchText = "glass"
        },
        .init(name: "album") { driver in
            driver.router.searchText = ""
            driver.router.section = .albums
            driver.router.navigate(to: .album(id: "al7", preview: nil))
        },
        .init(name: "artist") { driver in
            driver.router.navigate(to: .artist(id: "ar4", name: "Delta Static"))
            driver.notePath()
        },
        .init(name: "back") { driver in
            driver.notePath()
            driver.router.goBack()
            driver.notePath()
        },
        .init(name: "forward") { driver in
            driver.router.goForward()
            driver.notePath()
        },
        .init(name: "toast-over-sheet", settle: .milliseconds(900)) { driver in
            driver.router.present(.songInfo(Song(id: "so1", title: "Sheet", album: "", artist: "")))
            try? await Task.sleep(for: .seconds(1))
            driver.note("sheet presented")
            driver.app.toasts.show(.key("options.playNext"), style: .success)
            try? await Task.sleep(for: .milliseconds(300))
            driver.noteWindowOrder()
        },
        .init(name: "dismiss-sheet", captures: false) { driver in
            driver.router.sheet = nil
        },
        // Playback: the fake server streams silence, and the app volume
        // goes to 0 before anything plays all the same.
        .init(name: "player", settle: .seconds(2)) { driver in
            driver.app.player.setVolume(0)
            driver.router.section = .albums
            await driver.app.player.playAlbum(id: "al1")
            _ = await driver.waitUntil(timeout: .seconds(10)) { driver.app.player.isPlaying }
            try? await Task.sleep(for: .seconds(3))
            driver.notePlayer()
        },
        .init(name: "inspector-lyrics", settle: .seconds(3)) { driver in
            UserDefaults.standard.set(MacInspectorPanel.lyrics.rawValue, forKey: MacInspectorPanel.storageKey)
            driver.router.isNowPlayingPresented = true
            try? await Task.sleep(for: .seconds(3))
            driver.note("lyrics \(driver.app.lyrics.state)".prefix(160).description)
        },
        .init(name: "inspector-queue", settle: .seconds(2)) { driver in
            if let songs = try? await driver.app.repository.songs(ids: ["so20", "so31"]) {
                driver.app.player.enqueue(songs, position: .last)
            }
            UserDefaults.standard.set(MacInspectorPanel.queue.rawValue, forKey: MacInspectorPanel.storageKey)
            try? await Task.sleep(for: .seconds(1))
            driver.notePlayer()
        },
        .init(name: "queue-history", settle: .seconds(2)) { driver in
            // The song played past ten seconds, so skipping records it.
            driver.app.player.next()
            _ = await driver.waitUntil(timeout: .seconds(5)) { !driver.app.history.songs.isEmpty }
            driver.note("history \(driver.app.history.songs.map(\.title))")
        },
        // Keys: Space and Command-arrows play, pause and skip, except while
        // a text field is being edited.
        .init(name: "keys", captures: false) { driver in
            guard let window = driver.mainWindow else { return }
            let right = "\u{F703}"
            window.makeFirstResponder(nil)
            let wasPlaying = driver.app.player.isPlaying
            driver.press(" ", keyCode: 49)
            try? await Task.sleep(for: .milliseconds(800))
            driver.note("space: playing \(wasPlaying) -> \(driver.app.player.isPlaying)")
            driver.press(" ", keyCode: 49)
            try? await Task.sleep(for: .milliseconds(800))
            driver.note("space again: playing \(driver.app.player.isPlaying)")
            let player = driver.app.player
            let position = Int(player.clock.position())
            driver.press(right, keyCode: 124, modifiers: [.command, .option, .numericPad, .function])
            try? await Task.sleep(for: .milliseconds(800))
            driver.note("option-cmd-right: position \(position) -> \(Int(player.clock.position()))")
            let before = player.currentSong?.title ?? "-"
            driver.press(right, keyCode: 124, modifiers: [.command, .numericPad, .function])
            _ = await driver.waitUntil(timeout: .seconds(3)) { player.currentSong?.title != before }
            driver.note("cmd-right: \(before) -> \(player.currentSong?.title ?? "-")")
            // Down only: the app volume stays at 0.
            driver.press("\u{F701}", keyCode: 125, modifiers: [.command, .numericPad, .function])
            try? await Task.sleep(for: .milliseconds(300))
            driver.note("cmd-down: volume \(player.volume)")
            guard let field = driver.searchField(in: window) else {
                driver.note("no search field")
                return
            }
            window.makeFirstResponder(field)
            driver.note("first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
            let playing = driver.app.player.isPlaying
            let song = driver.app.player.currentSong?.title ?? "-"
            driver.press("a", keyCode: 0)
            driver.press(" ", keyCode: 49)
            driver.press("b", keyCode: 11)
            driver.press(right, keyCode: 124, modifiers: [.command, .numericPad, .function])
            try? await Task.sleep(for: .milliseconds(800))
            driver.note(
                "typing: text '\(driver.router.searchText)' playing \(playing) -> \(driver.app.player.isPlaying) "
                    + "song \(song) -> \(driver.app.player.currentSong?.title ?? "-")"
            )
            driver.router.searchText = ""
            window.makeFirstResponder(nil)
            driver.router.section = .albums
        },
        .init(name: "dock-menu", captures: false) { driver in
            let menu = MacAppDelegate().applicationDockMenu(NSApp)
            let items = menu?.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (disabled)") } ?? []
            driver.note("dock menu: \(items)")
        },
        .init(name: "settings", settle: .seconds(2)) { driver in
            driver.router.openSettings(.appearance)
            try? await Task.sleep(for: .seconds(2))
            driver.noteWindows("windows with settings")
        },
        .init(name: "close-settings", captures: false) { driver in
            for window in NSApp.windows where window.isVisible && window.identifier?.rawValue.hasPrefix(MacWindowID.main) != true {
                window.performClose(nil)
            }
        },
        .init(name: "debug-window", settle: .seconds(3)) { driver in
            driver.performMenuItem(titled: driver.app.localizer("native.mac.menu.debug"))
            try? await Task.sleep(for: .seconds(1))
            driver.noteWindows("windows with debug")
        },
        .init(name: "close-debug", captures: false) { driver in
            for window in NSApp.windows where window.isVisible && window.identifier?.rawValue.hasPrefix(MacWindowID.main) != true {
                window.performClose(nil)
            }
        },
        .init(name: "menus-language", captures: false) { driver in
            let previous = driver.app.settings.settings.languageCode
            driver.app.settings.update { $0.languageCode = "de" }
            try? await Task.sleep(for: .seconds(1))
            driver.dumpMenus(to: "menus-de.txt")
            driver.app.settings.update { $0.languageCode = previous }
            try? await Task.sleep(for: .milliseconds(500))
        },
        // Closing the window keeps the app and playback; the Dock brings
        // the window back.
        .init(name: "close-reopen", settle: .seconds(2)) { driver in
            let isMain = { (window: NSWindow) in window.identifier?.rawValue.hasPrefix(MacWindowID.main) == true }
            NSApp.windows.first { isMain($0) && $0.isVisible }?.performClose(nil)
            try? await Task.sleep(for: .seconds(2))
            driver.noteWindows("after close (playing \(driver.app.player.isPlaying))")
            let handled = MacAppDelegate().applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            _ = await driver.waitUntil(timeout: .seconds(5)) { NSApp.windows.contains { isMain($0) && $0.isVisible } }
            driver.noteWindows("after reopen (default handling \(handled), section \(driver.router.section.storageKey))")
        },
        .init(name: "player-paused") { driver in
            driver.app.player.pause()
            driver.app.player.seek(to: 14)
            driver.app.player.toggleShuffle()
            driver.app.player.cycleRepeat()
            try? await Task.sleep(for: .milliseconds(600))
            driver.notePlayer()
        },
        .init(name: "radio", settle: .seconds(3)) { driver in
            await driver.app.radios.load()
            driver.app.player.playRadio(driver.app.radios.stations, index: 0)
            _ = await driver.waitUntil(timeout: .seconds(10)) { driver.app.player.isRadio }
            driver.notePlayer()
        },
        .init(name: "stop-radio", captures: false) { driver in
            driver.app.player.pause()
            await driver.app.player.playAlbum(id: "al7", startingAt: 2)
            _ = await driver.waitUntil(timeout: .seconds(10)) { driver.app.player.isPlaying }
            driver.app.player.pause()
        },
    ]
}
#endif
