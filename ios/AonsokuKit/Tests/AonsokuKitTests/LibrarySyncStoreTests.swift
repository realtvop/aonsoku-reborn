import XCTest
@testable import AonsokuKit

@MainActor
final class LibrarySyncStoreTests: XCTestCase {
    func testStartupChoosesFullOrIncrementalAndSkipsConstrainedNetworks() throws {
        let unsynced = try LibrarySyncStoreFixture(
            availability: LibraryAvailability(available: false, lastSyncedAt: nil)
        )
        unsynced.settings.update {
            $0.cache.syncCoverArt = true
            $0.cache.coverArtConcurrency = 7
            $0.playback.useAlbumCoverForSongs = true
        }
        unsynced.store.start()
        XCTAssertEqual(unsynced.spy.full.count, 1)
        XCTAssertEqual(unsynced.spy.incremental.count, 0)
        XCTAssertEqual(unsynced.spy.full[0].coverArt?.concurrency, 7)
        XCTAssertEqual(unsynced.spy.full[0].coverArt?.useAlbumCoverForSongs, true)

        let syncedAt = 1_700_000_000_000
        let synced = try LibrarySyncStoreFixture(
            availability: LibraryAvailability(available: true, lastSyncedAt: syncedAt)
        )
        synced.store.start()
        XCTAssertEqual(synced.spy.incremental.count, 1)
        XCTAssertEqual(
            synced.store.lastSyncedAt,
            Date(timeIntervalSince1970: TimeInterval(syncedAt) / 1_000)
        )

        let offline = try LibrarySyncStoreFixture(connectivity: FixedConnectivity(isOnline: false))
        offline.store.start()
        XCTAssertTrue(offline.spy.full.isEmpty)
        XCTAssertTrue(offline.spy.incremental.isEmpty)

        let metered = try LibrarySyncStoreFixture(
            connectivity: FixedConnectivity(isOnline: true, isMetered: true)
        )
        metered.store.start()
        XCTAssertTrue(metered.spy.full.isEmpty)
        XCTAssertTrue(metered.spy.incremental.isEmpty)
        metered.store.syncNow()
        XCTAssertEqual(metered.spy.full.count, 1)
    }

    func testMapsPhasesAndCoalescesDataChanges() async throws {
        let fixture = try LibrarySyncStoreFixture()
        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "connecting", isSyncing: true, processedItems: 0, totalItems: 0
        )))
        XCTAssertEqual(fixture.store.phase, .waitingForConnection)
        XCTAssertTrue(fixture.store.isSyncing)
        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "songs",
            tier: "t3",
            isSyncing: true,
            processedItems: 3,
            totalItems: 10
        )))
        XCTAssertEqual(fixture.store.phase, .syncing(tier: "t3", processed: 3, total: 10))
        XCTAssertEqual(fixture.store.operation, "songs")
        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "coverArt",
            isSyncing: true,
            processedItems: 5,
            totalItems: 8
        )))
        XCTAssertEqual(fixture.store.phase, .coverArt(processed: 5, total: 8))
        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "error",
            isSyncing: false,
            processedItems: 0,
            totalItems: 0,
            message: "failed"
        )))
        XCTAssertEqual(fixture.store.phase, .failed("failed"))
        XCTAssertNil(fixture.store.operation)

        fixture.store.handle(.dataChanged(tables: ["albums"]))
        fixture.store.handle(.dataChanged(tables: ["songs"]))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fixture.store.revision, 1)

        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "done",
            isSyncing: false,
            processedItems: 0,
            totalItems: 0
        )))
        XCTAssertEqual(fixture.store.phase, .done)
        XCTAssertEqual(fixture.store.lastSyncedAt, fixture.clock.date)
    }

    func testForegroundThrottleCancelAndStop() throws {
        let fixture = try LibrarySyncStoreFixture(
            availability: LibraryAvailability(
                available: true,
                lastSyncedAt: Int(Date(timeIntervalSince1970: 100).timeIntervalSince1970 * 1_000)
            ),
            now: Date(timeIntervalSince1970: 500)
        )
        fixture.store.start()
        fixture.spy.incremental.removeAll()
        fixture.store.handleForeground()
        XCTAssertEqual(fixture.spy.incremental.count, 1)
        fixture.store.handleForeground()
        XCTAssertEqual(fixture.spy.incremental.count, 1)

        fixture.store.cancel()
        XCTAssertEqual(fixture.store.phase, .cancelled)
        XCTAssertEqual(fixture.spy.cancelCount, 1)
        fixture.store.stop()
        XCTAssertEqual(fixture.spy.cancelCount, 2)
        XCTAssertEqual(fixture.spy.unsubscribeCount, 1)
        XCTAssertEqual(fixture.store.phase, .idle)
    }

    func testSyncCompletionNotifiesDependentStoresOnlyAfterDone() throws {
        let fixture = try LibrarySyncStoreFixture()
        var completions = 0
        fixture.store.onSyncCompleted { completions += 1 }

        fixture.store.handle(.dataChanged(tables: ["songs"]))
        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "error",
            isSyncing: false,
            processedItems: 0,
            totalItems: 0
        )))
        XCTAssertEqual(completions, 0)

        fixture.store.handle(.syncStateChanged(LibrarySyncState(
            phase: "done",
            isSyncing: false,
            processedItems: 0,
            totalItems: 0
        )))
        XCTAssertEqual(completions, 1)
    }
}

@MainActor
private final class LibrarySyncStoreFixture {
    let database: TemporaryDatabase
    let library: LibraryService
    let settings: SettingsStore
    let spy: LibrarySyncOperationsSpy
    let clock: MutableDate
    let store: LibrarySyncStore

    init(
        availability: LibraryAvailability = LibraryAvailability(
            available: false,
            lastSyncedAt: nil
        ),
        connectivity: any Connectivity = FixedConnectivity(),
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) throws {
        database = try TemporaryDatabase()
        library = LibraryService(
            dbManager: database.manager,
            credentialsProvider: { nil }
        )
        settings = SettingsStore(preferences: PreferencesService(db: database.manager.dbPool))
        spy = LibrarySyncOperationsSpy(availability: availability)
        let clock = MutableDate(now)
        self.clock = clock
        store = LibrarySyncStore(
            library: library,
            settings: settings,
            connectivity: connectivity,
            operations: spy.operations,
            now: { clock.date }
        )
    }
}

private final class MutableDate: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private final class LibrarySyncOperationsSpy: @unchecked Sendable {
    var availabilityValue: LibraryAvailability
    var handler: LibraryService.EventHandler?
    var full: [LibrarySyncOptions] = []
    var incremental: [LibrarySyncOptions] = []
    var cancelCount = 0
    var unsubscribeCount = 0

    init(availability: LibraryAvailability) {
        availabilityValue = availability
    }

    var operations: LibrarySyncOperations {
        LibrarySyncOperations(
            availability: { [self] in availabilityValue },
            subscribe: { [self] handler in
                self.handler = handler
                return UUID()
            },
            unsubscribe: { [self] _ in unsubscribeCount += 1 },
            syncAll: { [self] in full.append($0) },
            syncIncremental: { [self] in incremental.append($0) },
            cancel: { [self] in cancelCount += 1 }
        )
    }
}
