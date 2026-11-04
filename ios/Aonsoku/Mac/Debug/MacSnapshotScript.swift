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
            driver.router.select(.home)
        },
        .init(name: "library") { driver in
            driver.router.select(.library)
        },
        .init(name: "album") { driver in
            driver.router.select(.home)
            driver.router.navigate(to: .album(id: "al7", preview: nil))
        },
        .init(name: "search") { driver in
            driver.router.select(.search)
        },
        .init(name: "account") { driver in
            driver.router.openSettings()
        },
    ]
}
#endif
