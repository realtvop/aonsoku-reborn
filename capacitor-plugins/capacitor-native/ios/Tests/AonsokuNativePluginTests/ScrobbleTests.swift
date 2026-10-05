import XCTest
@testable import AonsokuNativePlugin

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

    func testQueueExhaustionFlushesTheCurrentScrobbleSegment() throws {
        let database = try TemporaryDatabase()
        let clock = ManualClock()
        let buffer = NativeScrobbleBuffer(
            store: InMemoryScrobbleEntryStore(),
            now: clock.now
        )
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: buffer
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
