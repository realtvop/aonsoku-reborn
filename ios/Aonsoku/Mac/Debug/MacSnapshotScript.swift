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
