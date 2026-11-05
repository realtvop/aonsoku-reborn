import AVFoundation
import XCTest
@testable import AonsokuKit

/// What the audio service does as the machine is about to sleep and when the
/// connection may have changed. Nothing here sleeps the machine or reaches a
/// network: scrobbles go to a closure that records them, and every song is a
/// silent file on disk.
@MainActor
final class AudioServiceSleepTests: XCTestCase {
    // MARK: Saving the playback state

    func testSleepSavesThePlaybackStateBeforeItReturns() throws {
        let fixture = try SleepFixture()
        let queueEdited = expectation(description: "queue edited")
        queueEdited.assertForOverFulfill = false
        let token = fixture.service.subscribe { event in
            if case .queueContentsChanged = event { queueEdited.fulfill() }
        }
        defer { fixture.service.unsubscribe(token) }
        fixture.service.start()
        fixture.service.setContextQueue(
            songs: [fixture.song], currentIndex: 0, autoplay: false
        )
        fixture.service.addToUserQueue(songs: [makeSong("queued")], position: "last")
        wait(for: [queueEdited], timeout: 2)
        // Waits for the edits above, which run on the queue's own thread.
        _ = fixture.service.fullState()

        // Edits are written half a second after they are made, and the
        // machine may be asleep by then.
        try XCTSkipUnless(
            fixture.savedState == nil,
            "The delayed save ran before sleep, so there is nothing left to show."
        )
        fixture.service.applicationWillSleep()

        let saved = try XCTUnwrap(fixture.savedState)
        XCTAssertEqual(saved.contextSongs.map(\.id), ["tone"])
        XCTAssertEqual(saved.userQueue.map(\.id), ["queued"])
    }

    func testSleepWithNothingLoadedSavesNothingAndDoesNotFail() throws {
        let fixture = try SleepFixture()
        fixture.service.start()

        fixture.service.applicationWillSleep()
        fixture.service.connectionMayHaveChanged()

        XCTAssertNil(fixture.savedState)
        XCTAssertEqual(fixture.service.playbackSnapshot().state, .idle)
    }

    // MARK: Pending scrobbles

    func testSleepSendsTheScrobblesThatAreWaiting() async throws {
        let fixture = try ScrobbleFixture()

        fixture.service.applicationWillSleep()

        await fixture.expectDelivery()
    }

    func testAConnectionChangeSendsTheScrobblesThatAreWaiting() async throws {
        let fixture = try ScrobbleFixture()

        fixture.service.connectionMayHaveChanged()

        await fixture.expectDelivery()
    }

    func testScrobblesThatWereRefusedAreSentWhenTheConnectionReturns() async throws {
        let fixture = try ScrobbleFixture(accepting: false)
        fixture.service.applicationWillSleep()
        let attempted = await waitForPlayerStoreTest {
            fixture.requests.read { $0.count } == 1
        }
        XCTAssertTrue(attempted)
        // Refused, so the play stays buffered.
        XCTAssertEqual(fixture.buffer.getEntries().count, 1)

        fixture.accepting.update { $0 = true }
        // A submission that is still finishing makes a call a no-op, so ask
        // again until the retry has been made.
        let delivered = await waitForPlayerStoreTest {
            fixture.service.connectionMayHaveChanged()
            return fixture.buffer.getEntries().isEmpty
        }

        XCTAssertTrue(delivered)
        XCTAssertEqual(fixture.requests.read { $0 }, ["played:true", "played:true"])
    }

    func testNothingIsSentWithoutAnAccount() async throws {
        let fixture = try ScrobbleFixture(signedIn: false)

        fixture.service.applicationWillSleep()
        fixture.service.connectionMayHaveChanged()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(fixture.requests.read { $0 }.isEmpty)
        XCTAssertEqual(fixture.buffer.getEntries().count, 1)
    }

    // MARK: Playback

    func testSleepAndConnectionChangesLeaveAPausedSongAlone() async throws {
        let fixture = try SleepFixture()
        let events = LockedTestBox<[String]>([])
        fixture.service.start()
        fixture.service.setContextQueue(
            songs: [fixture.song], currentIndex: 0, autoplay: false
        )
        let paused = await waitForPlayerStoreTest {
            fixture.service.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(paused)
        let position = fixture.service.playbackSnapshot().currentTime
        let token = fixture.service.subscribe { event in
            switch event {
            case .playbackStateChanged, .error, .recoveryAttempt, .bufferingChanged:
                events.update { $0.append("\(event)") }
            default:
                break
            }
        }
        defer { fixture.service.unsubscribe(token) }

        fixture.service.applicationWillSleep()
        fixture.service.connectionMayHaveChanged()
        fixture.service.connectionMayHaveChanged()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(events.read { $0 }, [])
        XCTAssertEqual(fixture.service.playbackSnapshot().state, .paused)
        XCTAssertEqual(fixture.service.playbackSnapshot().currentTime, position)
    }
}

// MARK: - Fixtures

/// A service over a temporary database, with one silent song on disk.
@MainActor
private final class SleepFixture {
    let service: AudioService
    let song: QueueSong
    private let database: TemporaryDatabase

    init() throws {
        let database = try TemporaryDatabase()
        let url = database.directory.appendingPathComponent("tone.wav")
        try makeSilentWAVData(duration: 3).write(to: url)
        self.database = database
        song = QueueSong(
            id: "tone",
            title: "Song tone",
            artist: "Artist",
            album: "Album",
            duration: 3,
            streamUrl: url.absoluteString,
            cachedFileUri: url.absoluteString
        )
        service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
    }

    deinit {
        service.shutdown()
    }

    /// What a relaunch would restore.
    var savedState: PlaybackPersistState? {
        PlaybackStateRepository(db: database.manager.dbPool).load()
    }
}

/// A service holding one finished play that has not been sent to the server.
@MainActor
private final class ScrobbleFixture {
    let service: AudioService
    let buffer: NativeScrobbleBuffer
    /// `songId:submission` of every request the server was asked.
    let requests = LockedTestBox<[String]>([])
    /// Whether the server accepts requests.
    let accepting: LockedTestBox<Bool>
    private let database: TemporaryDatabase

    init(accepting: Bool = true, signedIn: Bool = true) throws {
        let database = try TemporaryDatabase()
        let requests = requests
        let acceptance = LockedTestBox(accepting)
        let credentials = ServerCredentials(
            serverUrl: "https://music.test",
            username: "user",
            password: "password",
            authType: "password",
            protocolVersion: "1.16.1",
            serverType: "navidrome",
            fallbackUrl: nil
        )
        let buffer = NativeScrobbleBuffer(store: SeededScrobbleStore([
            ScrobbleEntry(songId: "played", playedDurationMs: 200_000, timestamp: 1_700_000_000_000),
        ]))
        service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: buffer,
            scrobbleSubmitter: NativeScrobbleSubmitter(
                credentialsProvider: { signedIn ? credentials : nil },
                request: { _, songId, submission, _ in
                    requests.update { $0.append("\(songId):\(submission)") }
                    return acceptance.read { $0 }
                }
            )
        )
        self.buffer = buffer
        self.accepting = acceptance
        self.database = database
    }

    deinit {
        service.shutdown()
    }

    func expectDelivery(file: StaticString = #filePath, line: UInt = #line) async {
        let delivered = await waitForPlayerStoreTest { self.buffer.getEntries().isEmpty }
        XCTAssertTrue(delivered, "The play was never sent", file: file, line: line)
        XCTAssertEqual(requests.read { $0 }, ["played:true"], file: file, line: line)
    }
}

private final class SeededScrobbleStore: ScrobbleEntryStore {
    private var entries: [ScrobbleEntry]

    init(_ entries: [ScrobbleEntry]) {
        self.entries = entries
    }

    func load() -> [ScrobbleEntry] { entries }
    func save(_ entries: [ScrobbleEntry]) { self.entries = entries }
}
