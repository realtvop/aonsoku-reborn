import XCTest
@testable import AonsokuKit

final class ScrobbleTests: XCTestCase {
    func testTrackingUsesInjectedClockAndPreservesStartTimestamp() throws {
        let clock = ManualClock(milliseconds: 1_000)
        let store = InMemoryScrobbleEntryStore()
        let buffer = NativeScrobbleBuffer(store: store, now: clock.now)

        buffer.startTracking(songId: "song-1", duration: 200)
        clock.advance(milliseconds: 1_250)
        let entry = try XCTUnwrap(buffer.stopTracking())

        XCTAssertEqual(entry.songId, "song-1")
        XCTAssertEqual(entry.playedDurationMs, 1_250)
        XCTAssertEqual(entry.timestamp, 1_000)
        XCTAssertEqual(buffer.lastEntryDuration, 200)
        XCTAssertEqual(store.load(), [entry])
    }

    func testPauseExcludesPausedWallTimeAndResumeContinues() throws {
        let clock = ManualClock()
        let buffer = NativeScrobbleBuffer(
            store: InMemoryScrobbleEntryStore(),
            now: clock.now
        )
        buffer.startTracking(songId: "song-1")
        clock.advance(milliseconds: 750)
        buffer.pauseTracking()
        clock.advance(milliseconds: 5_000)
        buffer.resumeTracking()
        clock.advance(milliseconds: 250)

        XCTAssertEqual(try XCTUnwrap(buffer.stopTracking()).playedDurationMs, 1_000)
    }

    func testZeroDurationTrackingDoesNotCreateEntry() {
        let clock = ManualClock()
        let store = InMemoryScrobbleEntryStore()
        let buffer = NativeScrobbleBuffer(store: store, now: clock.now)

        buffer.startTracking(songId: "song-1")

        XCTAssertNil(buffer.stopTracking())
        XCTAssertTrue(buffer.getEntries().isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testStartingNewSongFlushesPreviousAndPersistenceRestoresOrder() {
        let clock = ManualClock()
        let store = InMemoryScrobbleEntryStore()
        let buffer = NativeScrobbleBuffer(store: store, now: clock.now)
        buffer.startTracking(songId: "song-1")
        clock.advance(milliseconds: 500)
        buffer.startTracking(songId: "song-2")
        clock.advance(milliseconds: 750)
        _ = buffer.stopTracking()

        let restored = NativeScrobbleBuffer(store: store, now: clock.now)

        XCTAssertEqual(restored.getEntries().map(\.songId), ["song-1", "song-2"])
        XCTAssertEqual(
            restored.getEntries().map(\.playedDurationMs),
            [500, 750]
        )
    }

    func testRemoveAndClearPersistMutations() {
        let clock = ManualClock()
        let store = InMemoryScrobbleEntryStore()
        let buffer = NativeScrobbleBuffer(store: store, now: clock.now)
        for id in ["one", "two"] {
            buffer.startTracking(songId: id)
            clock.advance(milliseconds: 100)
            _ = buffer.stopTracking()
        }

        buffer.removeEntries(songIds: ["one"])
        XCTAssertEqual(store.load().map(\.songId), ["two"])
        buffer.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testClearDiscardsActiveTracking() {
        let clock = ManualClock()
        let store = InMemoryScrobbleEntryStore()
        let buffer = NativeScrobbleBuffer(store: store, now: clock.now)
        buffer.startTracking(songId: "old-account")
        clock.advance(milliseconds: 1_000)

        buffer.clear()
        buffer.resumeTracking()
        clock.advance(milliseconds: 1_000)

        XCTAssertNil(buffer.stopTracking())
        XCTAssertNil(buffer.lastEntryDuration)
        XCTAssertTrue(buffer.getEntries().isEmpty)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSubmissionThresholdUsesHalfDurationCappedAtFourMinutes() {
        let submitter = NativeScrobbleSubmitter()
        let short = ScrobbleEntry(songId: "short", playedDurationMs: 59_999, timestamp: 1)
        let long = ScrobbleEntry(songId: "long", playedDurationMs: 240_000, timestamp: 1)

        XCTAssertFalse(submitter.isEligible(entry: short, songDurationSeconds: 120))
        XCTAssertTrue(submitter.isEligible(
            entry: ScrobbleEntry(
                songId: "short",
                playedDurationMs: 60_000,
                timestamp: 1
            ),
            songDurationSeconds: 120
        ))
        XCTAssertTrue(submitter.isEligible(entry: long, songDurationSeconds: 1_000))
        XCTAssertFalse(submitter.isEligible(entry: long, songDurationSeconds: 0))
    }

    func testInvalidationKeepsInFlightSubmissionBoundToOldAccount() async {
        let oldCredentials = makeCredentials(serverUrl: "https://old.test")
        let newCredentials = makeCredentials(serverUrl: "https://new.test")
        let activeCredentials = LockedTestBox(oldCredentials)
        let requests = LockedTestBox<[String]>([])
        let gate = ScrobbleRequestGate()
        let started = expectation(description: "submission started")
        let submitter = NativeScrobbleSubmitter(
            credentialsProvider: { activeCredentials.read { $0 } },
            request: { credentials, _, _, _ in
                requests.update { $0.append(credentials.serverUrl) }
                started.fulfill()
                return await gate.wait()
            }
        )
        let clock = ManualClock()
        let buffer = NativeScrobbleBuffer(
            store: InMemoryScrobbleEntryStore(),
            now: clock.now
        )
        buffer.startTracking(songId: "old-song")
        clock.advance(milliseconds: 1_000)
        _ = buffer.stopTracking()

        submitter.submitPending(buffer: buffer)
        await fulfillment(of: [started], timeout: 1)
        activeCredentials.update { $0 = newCredentials }
        submitter.invalidate()
        await gate.resume(returning: true)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(requests.read { $0 }, ["https://old.test"])
        XCTAssertEqual(buffer.getEntries().map(\.songId), ["old-song"])
    }

    func testPendingSubmissionRemovesOnlyEntriesThatSucceeded() async {
        let clock = ManualClock()
        let buffer = NativeScrobbleBuffer(
            store: InMemoryScrobbleEntryStore(),
            now: clock.now
        )
        buffer.startTracking(songId: "repeat")
        clock.advance(milliseconds: 100)
        guard let first = buffer.stopTracking() else {
            return XCTFail("first entry should be recorded")
        }
        buffer.startTracking(songId: "repeat")
        clock.advance(milliseconds: 200)
        guard let second = buffer.stopTracking() else {
            return XCTFail("second entry should be recorded")
        }
        XCTAssertEqual(buffer.getEntries(), [first, second])
        let requests = LockedTestBox(0)
        let attempted = expectation(description: "both entries attempted")
        attempted.expectedFulfillmentCount = 2
        let submitter = NativeScrobbleSubmitter(
            credentialsProvider: { makeCredentials(serverUrl: "https://music.test") },
            request: { _, _, _, _ in
                requests.update { $0 += 1 }
                let attempt = requests.read { $0 }
                attempted.fulfill()
                return attempt == 1
            }
        )

        submitter.submitPending(buffer: buffer)
        await fulfillment(of: [attempted], timeout: 1)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(buffer.getEntries(), [second])
    }

    func testConcurrentPendingSubmissionCallsShareOneRequest() async {
        let clock = ManualClock()
        let buffer = NativeScrobbleBuffer(
            store: InMemoryScrobbleEntryStore(),
            now: clock.now
        )
        buffer.startTracking(songId: "pending")
        clock.advance(milliseconds: 100)
        _ = buffer.stopTracking()
        let requests = LockedTestBox(0)
        let gate = ScrobbleBarrierGate()
        let submitter = NativeScrobbleSubmitter(
            credentialsProvider: { makeCredentials(serverUrl: "https://music.test") },
            request: { _, _, _, _ in
                requests.update { $0 += 1 }
                await gate.wait()
                return true
            }
        )

        submitter.submitPending(buffer: buffer)
        submitter.submitPending(buffer: buffer)
        let deadline = Date().addingTimeInterval(1)
        while requests.read({ $0 }) == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(requests.read { $0 }, 1)
        await gate.open()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(buffer.getEntries().isEmpty)
    }

    func testQueueExhaustionFlushesTheCurrentScrobbleSegment() throws {
        let database = try TemporaryDatabase()
        let clock = ManualClock()
        let buffer = NativeScrobbleBuffer(
            store: InMemoryScrobbleEntryStore(),
            now: clock.now
        )
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: buffer,
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        let ended = expectation(description: "queue exhaustion published")
        let token = service.subscribe { event in
            if case .playbackStateChanged(.ended, _) = event { ended.fulfill() }
        }

        buffer.startTracking(songId: "last-queue-song", duration: 200)
        clock.advance(milliseconds: 1_000)
        service.queueEngineDidExhaustQueue(NativeQueueEngine())
        wait(for: [ended], timeout: 1)

        let entry = try XCTUnwrap(buffer.getEntries().first)
        XCTAssertEqual(entry.songId, "last-queue-song")
        XCTAssertEqual(entry.playedDurationMs, 1_000)
        service.unsubscribe(token)
        service.shutdown()
    }
}

private func makeCredentials(serverUrl: String) -> ServerCredentials {
    ServerCredentials(
        serverUrl: serverUrl,
        username: "user",
        password: "password",
        authType: "password",
        protocolVersion: "1.16.1",
        serverType: "navidrome",
        fallbackUrl: nil
    )
}

private actor ScrobbleRequestGate {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning result: Bool) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: result)
        } else {
            self.result = result
        }
    }
}

private actor ScrobbleBarrierGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private final class ManualClock {
    private var date: Date

    init(milliseconds: Double = 0) {
        date = Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    func now() -> Date { date }

    func advance(milliseconds: Double) {
        date.addTimeInterval(milliseconds / 1_000)
    }
}

private final class InMemoryScrobbleEntryStore: ScrobbleEntryStore {
    private var entries: [ScrobbleEntry] = []

    func load() -> [ScrobbleEntry] { entries }
    func save(_ entries: [ScrobbleEntry]) { self.entries = entries }
}
