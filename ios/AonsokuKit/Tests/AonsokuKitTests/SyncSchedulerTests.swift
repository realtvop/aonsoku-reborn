import Foundation
import XCTest
@testable import AonsokuKit

final class SyncSchedulerTests: XCTestCase {
    func testEnteringTheBackgroundStopsTheForegroundSyncAndRequestsARefresh() throws {
        let fixture = try SchedulerFixture(self)
        fixture.scheduler.setForegroundSchedulingEnabled(true)
        XCTAssertTrue(fixture.scheduler.isForegroundTimerRunning)

        fixture.lifecycle.send(.didEnterBackground)

        XCTAssertFalse(fixture.scheduler.isForegroundTimerRunning)
        XCTAssertEqual(fixture.refresh.requests, [SyncScheduler.backgroundRefreshInterval])
    }

    func testABackgroundRefreshIsRequestedEvenWhenForegroundSyncIsOff() throws {
        let fixture = try SchedulerFixture(self)

        fixture.lifecycle.send(.didEnterBackground)
        fixture.lifecycle.send(.didEnterBackground)

        XCTAssertFalse(fixture.scheduler.isForegroundTimerRunning)
        XCTAssertEqual(
            fixture.refresh.requests,
            [SyncScheduler.backgroundRefreshInterval, SyncScheduler.backgroundRefreshInterval]
        )
    }

    func testForegroundSyncStaysOffWhileTheAppIsInTheBackground() throws {
        let fixture = try SchedulerFixture(self)
        fixture.lifecycle.send(.didEnterBackground)

        fixture.scheduler.setForegroundSchedulingEnabled(true)

        XCTAssertTrue(fixture.scheduler.isForegroundSchedulingEnabled)
        XCTAssertFalse(fixture.scheduler.isForegroundTimerRunning)
    }

    func testTurningForegroundSyncOffStopsTheTimer() throws {
        let fixture = try SchedulerFixture(self)
        fixture.scheduler.setForegroundSchedulingEnabled(true)

        fixture.scheduler.setForegroundSchedulingEnabled(false)

        XCTAssertFalse(fixture.scheduler.isForegroundSchedulingEnabled)
        XCTAssertFalse(fixture.scheduler.isForegroundTimerRunning)
    }

    @MainActor
    func testReturningToTheForegroundRestartsTheTimerAndSyncs() async throws {
        let fixture = try SchedulerFixture(self)
        fixture.scheduler.setForegroundSchedulingEnabled(true)
        fixture.lifecycle.send(.didEnterBackground)
        XCTAssertFalse(fixture.scheduler.isForegroundTimerRunning)
        XCTAssertTrue(fixture.requests.read { $0.isEmpty })

        fixture.lifecycle.send(.willEnterForeground)

        XCTAssertTrue(fixture.scheduler.isForegroundTimerRunning)
        let synced = await waitForPlayerStoreTest { fixture.requests.read { !$0.isEmpty } }
        XCTAssertTrue(synced)
    }

    @MainActor
    func testReturningToTheForegroundDoesNothingWhileForegroundSyncIsOff() async throws {
        let fixture = try SchedulerFixture(self)
        fixture.lifecycle.send(.didEnterBackground)

        fixture.lifecycle.send(.willEnterForeground)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(fixture.scheduler.isForegroundTimerRunning)
        XCTAssertTrue(fixture.requests.read { $0.isEmpty })
    }

    func testTheSchedulerObservesTheLifecycleItWasGiven() throws {
        let fixture = try SchedulerFixture(self)

        XCTAssertEqual(fixture.lifecycle.observerCount, 1)
    }

    // MARK: Background refresh

    func testRegisteringInstallsTheHandlerOnTheGivenScheduler() throws {
        let fixture = try SchedulerFixture(self)
        XCTAssertFalse(fixture.refresh.hasHandler)

        SyncScheduler.register(on: fixture.refresh)

        XCTAssertTrue(fixture.refresh.hasHandler)
    }

    @MainActor
    func testARefreshRunRequestsItsSuccessorSyncsAndCompletes() async throws {
        let fixture = try SchedulerFixture(self)
        SyncScheduler.register(on: fixture.refresh)
        let task = FakeRefreshTask()

        fixture.refresh.fire(task)

        // The next run is asked for at once, before the work can be cut short.
        XCTAssertEqual(fixture.refresh.requests, [SyncScheduler.backgroundRefreshInterval])
        XCTAssertNotNil(task.expirationHandler)
        let completed = await waitForPlayerStoreTest(timeout: .seconds(10)) {
            !task.completions.isEmpty
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(task.completions.count, 1)
        XCTAssertFalse(fixture.requests.read { $0.isEmpty })
    }

    @MainActor
    func testExpirationCancelsTheRunningRefresh() async throws {
        let entered = expectation(description: "The refresh reached the server")
        let gate = LockedTestBox<CheckedContinuation<Void, Never>?>(nil)
        let isFirst = LockedTestBox(true)
        let fixture = try SchedulerFixture(self) { _ in
            guard isFirst.read({ $0 }) else { return }
            isFirst.update { $0 = false }
            await withCheckedContinuation { continuation in
                gate.update { $0 = continuation }
                entered.fulfill()
            }
            try Task.checkCancellation()
        }
        SyncScheduler.register(on: fixture.refresh)
        let task = FakeRefreshTask()
        fixture.refresh.fire(task)
        await fulfillment(of: [entered], timeout: 10)

        task.expirationHandler?()
        gate.read { $0 }?.resume()

        let completed = await waitForPlayerStoreTest(timeout: .seconds(10)) {
            !task.completions.isEmpty
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(task.completions, [false])
    }
}

#if os(macOS)
final class ActivityRefreshSchedulerTests: XCTestCase {
    func testRequestsCanBeReplacedBeforeTheyRun() {
        let scheduler = ActivityRefreshScheduler(
            identifier: "github.realtvop.aonsoku.tests.refresh-\(UUID().uuidString)"
        )
        scheduler.register { task in task.setCompleted(success: true) }

        // Each request replaces the one before it, and a zero interval is
        // raised to something `NSBackgroundActivityScheduler` accepts.
        scheduler.schedule(after: 7_200)
        scheduler.schedule(after: 3_600)
        scheduler.schedule(after: 0)
    }

    func testSchedulingWithoutAHandlerIsHarmless() {
        let scheduler = ActivityRefreshScheduler(
            identifier: "github.realtvop.aonsoku.tests.refresh-\(UUID().uuidString)"
        )

        scheduler.schedule(after: 3_600)
    }

    func testThePlatformSchedulerForThisSystemUsesBackgroundActivities() {
        let scheduler = PlatformBackgroundRefresh.makeScheduler(
            identifier: "github.realtvop.aonsoku.tests.refresh-\(UUID().uuidString)"
        )

        XCTAssertTrue(scheduler is ActivityRefreshScheduler)
    }
}
#endif

// MARK: - Fixtures

private final class SchedulerFixture {
    let lifecycle = FakeLifecycle()
    let refresh = FakeBackgroundRefresh()
    let requests = LockedTestBox<[String]>([])
    let scheduler: SyncScheduler
    private let database: TemporaryDatabase
    private let engine: SyncEngine

    init(
        _ test: XCTestCase,
        onRequest: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) throws {
        let database = try TemporaryDatabase()
        let requests = requests
        let engine = SyncEngine(
            db: database.manager.dbPool,
            httpClient: RecordingSyncHTTPClient { path in
                requests.update { $0.append(path) }
                try await onRequest(path)
                return SubsonicResponse(data: [:], count: 0)
            },
            credentialsProvider: { Self.credentials }
        )
        let scheduler = SyncScheduler(
            syncEngine: engine,
            lifecycle: lifecycle,
            backgroundRefresh: refresh
        )
        self.database = database
        self.engine = engine
        self.scheduler = scheduler
        // The scheduler outlives the test as the process-wide `shared`
        // instance, so its timer and any sync it started are stopped here.
        test.addTeardownBlock {
            scheduler.setForegroundSchedulingEnabled(false)
            engine.cancel()
        }
    }

    private static var credentials: ServerCredentials {
        ServerCredentials(
            serverUrl: "https://music.test", username: "user", password: "secret",
            authType: "password", protocolVersion: "1.16.1", serverType: "navidrome",
            fallbackUrl: nil
        )
    }
}

private struct RecordingSyncHTTPClient: LibrarySyncHTTPClient {
    let handler: (String) async throws -> SubsonicResponse

    init(_ handler: @escaping (String) async throws -> SubsonicResponse) {
        self.handler = handler
    }

    func request(baseUrl: String, path: String, credentials: ServerCredentials,
                 extraQuery: [String: String], method: String) async throws -> SubsonicResponse {
        try await handler(path)
    }
}

private final class FakeLifecycle: ApplicationLifecycleObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (ApplicationLifecycleEvent) -> Void] = [:]

    var observerCount: Int { lock.withLock { handlers.count } }

    func observe(
        _ handler: @escaping @Sendable (ApplicationLifecycleEvent) -> Void
    ) -> ObservationToken {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return ObservationToken { [weak self] in
            self?.lock.withLock { self?.handlers[id] = nil }
        }
    }

    func send(_ event: ApplicationLifecycleEvent) {
        let all = lock.withLock { Array(handlers.values) }
        all.forEach { $0(event) }
    }
}

private final class FakeBackgroundRefresh: BackgroundRefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (BackgroundRefreshTask) -> Void)?
    private var intervals: [TimeInterval] = []

    var hasHandler: Bool { lock.withLock { handler != nil } }
    var requests: [TimeInterval] { lock.withLock { intervals } }

    func register(handler: @escaping @Sendable (BackgroundRefreshTask) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func schedule(after interval: TimeInterval) {
        lock.withLock { intervals.append(interval) }
    }

    /// Runs the registered handler as the system would when a refresh fires.
    func fire(_ task: BackgroundRefreshTask) {
        let handler = lock.withLock { self.handler }
        handler?(task)
    }
}

private final class FakeRefreshTask: BackgroundRefreshTask, @unchecked Sendable {
    var expirationHandler: (() -> Void)?
    private let results = LockedTestBox<[Bool]>([])

    var completions: [Bool] { results.read { $0 } }

    func setCompleted(success: Bool) {
        results.update { $0.append(success) }
    }
}
