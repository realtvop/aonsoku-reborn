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

    // MARK: Connection changes (a Mac waking from sleep or switching network)

    func testConnectionChangeNeedsAStartedStoreAndAnUnmeteredConnection() throws {
        let connectivity = LockedConnectivity(isOnline: false, isMetered: false)
        let fixture = try LibrarySyncStoreFixture(connectivity: connectivity)

        fixture.store.resumeAfterConnectionChange()
        XCTAssertEqual(fixture.spy.runCount, 0, "not started")

        fixture.store.start()
        fixture.store.handle(Self.event("error", message: "down"))
        fixture.store.resumeAfterConnectionChange()
        XCTAssertEqual(fixture.spy.runCount, 0, "offline")

        connectivity.update(isOnline: true, isMetered: true)
        fixture.store.resumeAfterConnectionChange()
        XCTAssertEqual(fixture.spy.runCount, 0, "metered")

        connectivity.update(isOnline: true, isMetered: false)
        fixture.store.resumeAfterConnectionChange()
        XCTAssertEqual(fixture.spy.runCount, 1, "the guards were the only obstacle")
    }

    func testConnectionChangeRunsAFailedSyncAgainAtOnce() throws {
        // A library that never finished syncing starts over with a full sync.
        let unsynced = try LibrarySyncStoreFixture()
        unsynced.store.start()
        unsynced.store.handle(Self.event("error", message: "down"))
        XCTAssertEqual(unsynced.store.phase, .failed("down"))
        unsynced.store.resumeAfterConnectionChange()
        XCTAssertEqual(unsynced.spy.full.count, 2)
        XCTAssertTrue(unsynced.spy.incremental.isEmpty)
        XCTAssertEqual(unsynced.store.phase, .waitingForConnection)
        XCTAssertTrue(unsynced.store.isSyncing)

        // A synced one is updated, even though it was synced a moment ago and
        // a return to the foreground would wait for five minutes.
        let synced = try LibrarySyncStoreFixture(
            availability: LibraryAvailability(available: true, lastSyncedAt: 1_000_000),
            now: Date(timeIntervalSince1970: 1_000)
        )
        synced.store.start()
        XCTAssertEqual(synced.spy.incremental.count, 1)
        synced.store.handle(Self.event("error", message: "down"))
        synced.store.resumeAfterConnectionChange()
        XCTAssertEqual(synced.spy.incremental.count, 2)
        XCTAssertTrue(synced.spy.full.isEmpty)
    }

    func testRepeatedConnectionChangesStartASingleSync() throws {
        let fixture = try LibrarySyncStoreFixture()
        fixture.store.start()
        fixture.store.handle(Self.event("error", message: "down"))

        // Wake, then the network coming back, before the engine has reported
        // anything about the sync the first one started.
        for _ in 0..<3 { fixture.store.resumeAfterConnectionChange() }
        XCTAssertEqual(fixture.spy.runCount, 2, "the startup sync and one more")

        // The sync those changes interrupted failed: it is run once more, and
        // that failure ends it.
        fixture.store.handle(Self.event("error", message: "reset"))
        XCTAssertEqual(fixture.spy.runCount, 3)
        fixture.store.handle(Self.event("error", message: "reset"))
        XCTAssertEqual(fixture.spy.runCount, 3)
        XCTAssertEqual(fixture.store.phase, .failed("reset"))
    }

    func testSyncRunningDuringAConnectionChangeIsRetriedOnlyIfItFails() throws {
        func runningSyncAcrossAChange() throws -> LibrarySyncStoreFixture {
            let fixture = try LibrarySyncStoreFixture()
            fixture.store.start()
            fixture.store.handle(Self.event("songs", syncing: true))
            fixture.store.resumeAfterConnectionChange()
            XCTAssertEqual(fixture.spy.runCount, 1, "a running sync is left alone")
            XCTAssertEqual(fixture.store.phase, .syncing(tier: nil, processed: 0, total: 0))
            return fixture
        }

        let finishes = try runningSyncAcrossAChange()
        finishes.store.handle(Self.event("done"))
        XCTAssertEqual(finishes.spy.runCount, 1)
        // The change was dealt with: a later, unrelated failure is not retried.
        finishes.store.handle(Self.event("error", message: "later"))
        XCTAssertEqual(finishes.spy.runCount, 1)

        let cancelled = try runningSyncAcrossAChange()
        cancelled.store.handle(Self.event("cancelled"))
        cancelled.store.handle(Self.event("error", message: "later"))
        XCTAssertEqual(cancelled.spy.runCount, 1)

        let fails = try runningSyncAcrossAChange()
        fails.store.handle(Self.event("error", message: "reset"))
        XCTAssertEqual(fails.spy.runCount, 2)
        XCTAssertEqual(fails.store.phase, .waitingForConnection)
    }

    func testFailureAfterTheConnectionWentAwayIsNotRetried() throws {
        let connectivity = LockedConnectivity(isOnline: true, isMetered: false)
        let fixture = try LibrarySyncStoreFixture(connectivity: connectivity)
        fixture.store.start()
        fixture.store.handle(Self.event("songs", syncing: true))
        fixture.store.resumeAfterConnectionChange()

        connectivity.update(isOnline: false, isMetered: false)
        fixture.store.handle(Self.event("error", message: "offline"))
        XCTAssertEqual(fixture.spy.runCount, 1)
        XCTAssertEqual(fixture.store.phase, .failed("offline"))

        // The pending retry was used up, not kept for the next failure.
        connectivity.update(isOnline: true, isMetered: false)
        fixture.store.handle(Self.event("error", message: "again"))
        XCTAssertEqual(fixture.spy.runCount, 1)
    }

    func testStoppingForgetsARetryPendingForTheOldSession() throws {
        let fixture = try LibrarySyncStoreFixture()
        fixture.store.start()
        fixture.store.handle(Self.event("songs", syncing: true))
        fixture.store.resumeAfterConnectionChange()

        fixture.store.stop()
        fixture.store.start()
        XCTAssertEqual(fixture.spy.runCount, 2)
        fixture.store.handle(Self.event("error", message: "unrelated"))
        XCTAssertEqual(fixture.spy.runCount, 2)
    }

    func testConnectionChangeWithoutAFailureIsAForegroundReturn() throws {
        // Last synced ten minutes ago: updated now, and not again right away.
        let stale = try LibrarySyncStoreFixture(
            availability: LibraryAvailability(available: true, lastSyncedAt: 100_000),
            now: Date(timeIntervalSince1970: 700)
        )
        stale.store.start()
        stale.spy.incremental.removeAll()
        stale.store.resumeAfterConnectionChange()
        XCTAssertEqual(stale.spy.incremental.count, 1)
        stale.store.resumeAfterConnectionChange()
        XCTAssertEqual(stale.spy.incremental.count, 1)

        // Synced a minute ago: nothing to do.
        let recent = try LibrarySyncStoreFixture(
            availability: LibraryAvailability(available: true, lastSyncedAt: 640_000),
            now: Date(timeIntervalSince1970: 700)
        )
        recent.store.start()
        recent.spy.incremental.removeAll()
        recent.store.resumeAfterConnectionChange()
        XCTAssertEqual(recent.spy.runCount, 0)
    }

    private static func event(
        _ phase: String,
        syncing: Bool = false,
        message: String? = nil
    ) -> LibraryEvent {
        .syncStateChanged(LibrarySyncState(
            phase: phase,
            isSyncing: syncing,
            processedItems: 0,
            totalItems: 0,
            message: message
        ))
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

    /// Syncs started, of either kind.
    var runCount: Int { full.count + incremental.count }

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
