import XCTest

@testable import AonsokuKit

// The state behind Settings → Storage → "Import downloads from Aonsoku
// Desktop…": what the store shows while it scans, imports, is cancelled or
// signed out, and that removing imported downloads leaves the desktop app's
// folder alone. The importer itself is covered by
// `DesktopDownloadsImporterTests`; both build the desktop app's folder with
// `ElectronUserDataFixture` in a temporary directory.

/// A `DownloadsStore` over the app's own scratch layout and the fixture's
/// "Electron folder".
@MainActor
private final class StoreWorld {
    let world: ImportWorld
    let library: LibraryService
    let audio: AudioService
    let store: DownloadsStore

    init(_ test: XCTestCase) throws {
        world = try ImportWorld(test)
        library = LibraryService(
            dbManager: world.database.manager,
            credentialsProvider: { nil }
        )
        audio = AudioService(
            databaseManager: world.database.manager,
            storage: world.layout,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        let repository = LibraryRepository(
            api: FakeSubsonicAPI(),
            library: library,
            connectivity: FixedConnectivity()
        )
        let settings = SettingsStore(
            preferences: PreferencesService(db: world.database.manager.dbPool)
        )
        store = DownloadsStore(
            audio: audio,
            library: library,
            repository: repository,
            settings: settings,
            now: { ImportWorld.now }
        )
        let location = world.location
        store.desktopLocator = { location }
    }

    func shutdown() {
        store.stop()
        audio.shutdown()
    }

    /// Polls until `condition` holds, so the test never waits on a fixed delay.
    func wait(
        timeout: TimeInterval = 15,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

/// Holds one copy until the test lets it go, to look at a running import.
private final class TransferGate: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private var calls = 0
    private let holdAt: Int

    init(holdAt: Int) {
        self.holdAt = holdAt
    }

    var transfer: DesktopFileTransfer {
        DesktopFileTransfer { [self] source, destination, isCancelled in
            lock.lock()
            calls += 1
            let call = calls
            lock.unlock()
            if call == holdAt {
                entered.signal()
                released.wait()
            }
            try DesktopFileCopier.copy(from: source, to: destination, isCancelled: isCancelled)
        }
    }

    private func blockUntilHeld() -> Bool {
        entered.wait(timeout: .now() + 15) == .success
    }

    /// Whether the held copy was reached within 15 seconds.
    func waitUntilHeld() async -> Bool {
        await Task.detached { self.blockUntilHeld() }.value
    }

    func release() {
        released.signal()
    }
}

#if os(macOS)
@MainActor
final class DesktopImportStoreTests: XCTestCase {
    func testTheRowIsOfferedAndStartsIdle() throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }

        XCTAssertTrue(DownloadsStore.supportsDesktopImport)
        XCTAssertEqual(fixture.store.desktopImport, .idle)
        XCTAssertFalse(fixture.store.desktopImport.isBusy)
    }

    func testScanSummarisesWhatAnImportWouldDo() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let electron = fixture.world.electron
        try electron.addSong("alpha", size: 4_096)
        try electron.addSong("beta", contentType: "audio/flac", size: 9_000)
        try electron.addSong("gamma", size: 100)
        try electron.addInterruptedDownload("partial")
        try fixture.world.plant(name: "broken", json: "not json")
        // The app has beta already, as a streamed copy.
        try fixture.world.installAppCopy("beta", bytes: Data(repeating: 1, count: 50))
        try fixture.world.installRow("beta", source: .lru, size: 50)

        await fixture.store.refreshDesktopDownloads()

        XCTAssertEqual(
            fixture.store.desktopImport,
            .ready(DesktopDownloadsSummary(
                songCount: 3,
                totalBytes: 4_096 + 9_000 + 100,
                importableCount: 3,
                importableBytes: 4_096 + 100,
                skipped: 1,
                isPicked: false
            ))
        )
        XCTAssertEqual(fixture.world.appCacheListing().count, 2, "a scan wrote to the app's cache")
    }

    func testScanReportsFoldersThatCannotBeUsed() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let world = fixture.world

        // The sandbox does not let the app look at the default place.
        fixture.store.desktopLocator = { nil }
        await fixture.store.refreshDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unreadable)

        // Or there is no desktop app on this Mac.
        let missing = DesktopDataLocator.location(
            forDirectory: world.parent.appendingPathComponent("nothing", isDirectory: true),
            isPicked: false
        )
        fixture.store.desktopLocator = { missing }
        await fixture.store.refreshDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unreadable)

        // A desktop app that never downloaded anything.
        fixture.store.desktopLocator = { world.location }
        try FileManager.default.removeItem(at: world.electron.audioCache)
        await fixture.store.refreshDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .empty(isPicked: false))
        await fixture.store.chooseDesktopDownloads(at: world.electron.root)
        XCTAssertEqual(fixture.store.desktopImport, .empty(isPicked: true))

        // It downloads something, and a new look finds it.
        try FileManager.default.createDirectory(
            at: world.electron.audioCache, withIntermediateDirectories: true
        )
        try world.electron.addSong("late", size: 10)
        await fixture.store.refreshDesktopDownloads()
        guard case let .ready(summary) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(summary.songCount, 1)
    }

    func testChoosingTheDataFolderOrItsDownloadsFolder() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let electron = fixture.world.electron
        try electron.addSong("one", size: 10)
        try electron.addSong("two", size: 20)
        fixture.store.desktopLocator = { nil } // the default place is not readable

        await fixture.store.chooseDesktopDownloads(at: electron.root)
        guard case let .ready(fromData) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(fromData.songCount, 2)
        XCTAssertTrue(fromData.isPicked)

        await fixture.store.chooseDesktopDownloads(at: electron.audioCache)
        guard case let .ready(fromCache) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(fromCache.songCount, 2)
        XCTAssertTrue(fromCache.isPicked)

        // The chosen folder is the one the import uses, not the default place.
        await fixture.store.importDesktopDownloads()
        guard case let .finished(result) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(result.imported, 2)

        // A folder that is not the desktop app's.
        let elsewhere = fixture.world.parent.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        await fixture.store.chooseDesktopDownloads(at: elsewhere)
        XCTAssertEqual(fixture.store.desktopImport, .empty(isPicked: true))
    }

    func testRescanStaysOnTheChosenFolderButRefreshStartsOver() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let electron = fixture.world.electron
        try electron.addSong("one", size: 10)
        fixture.store.desktopLocator = { nil } // the default place is not readable

        // Nothing is known yet, so a rescan starts at the default place.
        await fixture.store.rescanDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unreadable)

        await fixture.store.chooseDesktopDownloads(at: electron.root)
        try electron.addSong("two", size: 20)
        await fixture.store.rescanDesktopDownloads()
        guard case let .ready(summary) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(summary.songCount, 2)
        XCTAssertTrue(summary.isPicked, "a rescan went back to the default place")

        await fixture.store.refreshDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unreadable)
    }

    func testImportingRegistersDownloadsAndUpdatesTheStorageNumbers() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let sizes = ["alpha": 4_096, "beta": 9_000, "gamma": 100]
        for (id, size) in sizes { try fixture.world.electron.addSong(id, size: size) }
        fixture.store.start()
        let revision = fixture.store.revision
        XCTAssertEqual(fixture.store.usage.explicit.count, 0)

        await fixture.store.refreshDesktopDownloads()
        await fixture.store.importDesktopDownloads()

        guard case let .finished(result) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.failures, [])
        for id in sizes.keys {
            XCTAssertEqual(
                fixture.store.state(ofSong: id),
                .cached(source: .explicit, removedFromServer: false),
                id
            )
        }
        XCTAssertEqual(fixture.store.usage.explicit.count, 3)
        XCTAssertEqual(fixture.store.usage.explicit.sizeBytes, Int64(sizes.values.reduce(0, +)))
        XCTAssertGreaterThan(fixture.store.revision, revision, "Storage lists did not reload")
        let listed = await fixture.store.items(filter: .explicit).map(\.itemId)
        XCTAssertEqual(Set(listed), Set(sizes.keys))

        // Looking again: everything is here, and importing again changes nothing.
        await fixture.store.refreshDesktopDownloads()
        guard case let .ready(summary) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertTrue(summary.isUpToDate)
        XCTAssertEqual(summary.importableBytes, 0)
        await fixture.store.importDesktopDownloads()
        guard case let .finished(again) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(again.imported, 0)
        XCTAssertEqual(again.alreadyPresent, 3)
    }

    func testImportingWithoutALookFirstUsesTheDefaultPlace() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        try fixture.world.electron.addSong("direct", size: 64)
        fixture.store.start()

        await fixture.store.importDesktopDownloads()

        guard case let .finished(result) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(
            fixture.store.state(ofSong: "direct"),
            .cached(source: .explicit, removedFromServer: false)
        )

        // Nowhere to look.
        fixture.store.desktopLocator = { nil }
        fixture.store.resetDesktopImport()
        await fixture.store.importDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unreadable)
    }

    func testAnImportShowsItsProgressAndIgnoresRequestsWhileBusy() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        for id in ["song-1", "song-2", "song-3"] {
            try fixture.world.electron.addSong(id, size: 2_000)
        }
        let gate = TransferGate(holdAt: 2)
        fixture.store.desktopTransfer = gate.transfer
        fixture.store.start()
        await fixture.store.refreshDesktopDownloads()

        let run = Task { await fixture.store.importDesktopDownloads() }
        let held = await gate.waitUntilHeld()
        XCTAssertTrue(held, "the second copy was never reached")
        let progressed = await fixture.wait {
            if case let .importing(progress) = fixture.store.desktopImport {
                return progress.completed == 1
            }
            return false
        }
        XCTAssertTrue(progressed, "\(fixture.store.desktopImport)")
        guard case let .importing(progress) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.totalBytes, 6_000)
        XCTAssertEqual(progress.bytesCopied, 2_000)
        XCTAssertEqual(progress.fraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertTrue(fixture.store.desktopImport.isBusy)

        // A second request while this one runs does nothing at all.
        await fixture.store.importDesktopDownloads()
        await fixture.store.refreshDesktopDownloads()
        await fixture.store.chooseDesktopDownloads(at: fixture.world.electron.root)
        guard case .importing = fixture.store.desktopImport else {
            return XCTFail("a request while busy changed the state: \(fixture.store.desktopImport)")
        }

        gate.release()
        await run.value

        guard case let .finished(result) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(result.imported, 3)
        XCTAssertFalse(fixture.store.desktopImport.isBusy)
    }

    func testCancellingKeepsFinishedSongsAndALaterImportCarriesOn() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        for id in ["song-1", "song-2", "song-3"] {
            try fixture.world.electron.addSong(id, size: 2_000)
        }
        let gate = TransferGate(holdAt: 2)
        fixture.store.desktopTransfer = gate.transfer
        fixture.store.start()
        await fixture.store.refreshDesktopDownloads()

        let run = Task { await fixture.store.importDesktopDownloads() }
        let held = await gate.waitUntilHeld()
        XCTAssertTrue(held)
        fixture.store.cancelDesktopImport()
        gate.release()
        await run.value

        guard case let .finished(result) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertTrue(result.wasCancelled)
        XCTAssertGreaterThanOrEqual(result.imported, 1)
        XCTAssertLessThan(result.imported, 3)
        XCTAssertEqual(
            fixture.store.usage.explicit.count, result.imported,
            "the storage numbers did not follow a cancelled import"
        )
        XCTAssertEqual(try fixture.world.index.getAll(type: "audio").count, result.imported)
        let done = result.imported

        // Looking again shows what is left.
        await fixture.store.rescanDesktopDownloads()
        guard case let .ready(remaining) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(remaining.songCount, 3)
        XCTAssertEqual(remaining.importableCount, 3 - done)

        // Without the gate: the rest.
        fixture.store.desktopTransfer = nil
        await fixture.store.importDesktopDownloads()
        guard case let .finished(rest) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertFalse(rest.wasCancelled)
        XCTAssertEqual(rest.imported, 3 - done)
        XCTAssertEqual(rest.alreadyPresent, done)
        XCTAssertEqual(fixture.store.usage.explicit.count, 3)
    }

    func testSigningOutDuringAnImportStopsItAndPublishesNothing() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        for id in ["song-1", "song-2", "song-3"] {
            try fixture.world.electron.addSong(id, size: 2_000)
        }
        let gate = TransferGate(holdAt: 2)
        fixture.store.desktopTransfer = gate.transfer
        fixture.store.start()
        await fixture.store.refreshDesktopDownloads()

        let run = Task { await fixture.store.importDesktopDownloads() }
        let held = await gate.waitUntilHeld()
        XCTAssertTrue(held)
        fixture.store.stop() // sign-out
        XCTAssertEqual(fixture.store.desktopImport, .idle)
        gate.release()
        await run.value

        XCTAssertEqual(fixture.store.desktopImport, .idle, "a late result reached the next account")
        XCTAssertEqual(fixture.store.usage.explicit.count, 0)
        XCTAssertNil(try fixture.world.row("song-3"), "the import carried on after sign-out")

        // The next account can look again.
        fixture.store.desktopTransfer = nil
        fixture.store.start()
        await fixture.store.refreshDesktopDownloads()
        guard case .ready = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
    }

    func testFailuresBecomeStates() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let world = fixture.world
        try world.electron.addSong("one", size: 4_096)
        fixture.store.start()

        // Not enough room on the Mac.
        fixture.store.desktopAvailableCapacity = { _ in 1_000 }
        await fixture.store.refreshDesktopDownloads()
        await fixture.store.importDesktopDownloads()
        guard case let .failed(.insufficientSpace(required, available)) = fixture.store.desktopImport
        else { return XCTFail("\(fixture.store.desktopImport)") }
        XCTAssertEqual(available, 1_000)
        XCTAssertGreaterThan(required, 4_096)
        XCTAssertEqual(world.appCacheListing(), [])
        XCTAssertFalse(fixture.store.desktopImport.isBusy, "the row stays usable after a failure")

        // The user picks the app's own downloads.
        fixture.store.desktopAvailableCapacity = nil
        try world.installAppCopy("own", bytes: Data(repeating: 4, count: 30))
        await fixture.store.chooseDesktopDownloads(at: world.layout.audioCacheDirectory)
        await fixture.store.importDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .failed(.sourceIsDestination))

        // The desktop app's folder disappears between the look and the import.
        await fixture.store.refreshDesktopDownloads()
        guard case .ready = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        try FileManager.default.removeItem(at: world.electron.root)
        await fixture.store.importDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unreadable)
    }

    func testRemovingImportedDownloadsLeavesTheDesktopFolderByteIdentical() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        let world = fixture.world
        for id in ["song-1", "song-2", "song-3", "song-4"] {
            try world.electron.addSong(id, size: 3_000)
        }
        try world.electron.addInterruptedDownload("partial")
        try world.electron.makeReadOnly(for: self)
        let before = try world.electron.snapshot()
        fixture.store.start()

        await fixture.store.refreshDesktopDownloads()
        await fixture.store.importDesktopDownloads()
        XCTAssertEqual(fixture.store.usage.explicit.count, 4)
        XCTAssertEqual(try world.electron.snapshot(), before)

        await fixture.store.remove(songIds: ["song-1"])
        XCTAssertEqual(fixture.store.state(ofSong: "song-1"), .notCached)
        XCTAssertEqual(try world.electron.snapshot(), before)

        let items = await fixture.store.items(filter: .explicit)
        let two = items.filter { $0.itemId == "song-2" }
        XCTAssertEqual(two.count, 1)
        await fixture.store.delete(two)
        XCTAssertEqual(fixture.store.state(ofSong: "song-2"), .notCached)
        XCTAssertEqual(try world.electron.snapshot(), before)

        await fixture.store.clear(source: .explicit)
        XCTAssertEqual(fixture.store.usage.explicit.count, 0)
        XCTAssertEqual(world.appCacheListing(), [], "the app's own copies are gone")
        XCTAssertEqual(try world.electron.snapshot(), before, "the desktop folder changed")

        // The desktop app still has everything, so it can be imported again.
        await fixture.store.refreshDesktopDownloads()
        guard case let .ready(summary) = fixture.store.desktopImport else {
            return XCTFail("\(fixture.store.desktopImport)")
        }
        XCTAssertEqual(summary.importableCount, 4)
        XCTAssertEqual(try world.electron.snapshot(), before)
    }
}
#else
@MainActor
final class DesktopImportUnsupportedPlatformTests: XCTestCase {
    func testPlatformsWithoutADesktopAppNeverOfferTheImport() async throws {
        let fixture = try StoreWorld(self)
        defer { fixture.shutdown() }
        try fixture.world.electron.addSong("one", size: 64)

        XCTAssertFalse(DownloadsStore.supportsDesktopImport)
        XCTAssertEqual(fixture.store.desktopImport, .unavailable)
        await fixture.store.refreshDesktopDownloads()
        await fixture.store.chooseDesktopDownloads(at: fixture.world.electron.root)
        await fixture.store.importDesktopDownloads()
        XCTAssertEqual(fixture.store.desktopImport, .unavailable)
        XCTAssertNil(DesktopDataLocator.defaultLocation())
        XCTAssertNil(DesktopDataLocator.location(forPicked: fixture.world.electron.root))
        XCTAssertEqual(fixture.world.appCacheListing(), [])
    }
}
#endif
