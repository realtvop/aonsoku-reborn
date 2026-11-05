import AVFoundation
import XCTest
@testable import AonsokuKit

/// Quitting the app and starting it again, as a Mac does on Command-Q: what
/// the audio service writes on its way out and what it restores on the way in.
/// Every song is a silent file on disk, and nothing here plays it.
@MainActor
final class AudioServiceTerminationTests: XCTestCase {
    func testQuittingKeepsWhereAPausedSongWas() async throws {
        let session = try QuitSession()
        try await session.loadPaused(at: 1.5)

        session.service.applicationWillTerminate()
        try await session.letTheServiceFinishSaving()

        let saved = try XCTUnwrap(session.savedState)
        XCTAssertEqual(saved.currentTime, 1.5, accuracy: 0.1)
        XCTAssertEqual(saved.contextSongs.map(\.id), ["tone"])
        XCTAssertEqual(saved.userQueue.map(\.id), ["queued"])
    }

    func testNothingIsSavedAfterShuttingDown() async throws {
        let session = try QuitSession()
        try await session.loadPaused(at: 1.5)
        session.service.shutdown()

        // A save that starts once the player is gone cannot read the position
        // and would write the start of the song. An edit schedules the next
        // one, and the wait outlasts its half-second timer.
        session.service.addToUserQueue(songs: [makeSong("later")], position: "last")
        _ = session.service.fullState()
        try await Task.sleep(for: .milliseconds(800))

        let saved = try XCTUnwrap(session.savedState)
        XCTAssertEqual(saved.userQueue.map(\.id), ["queued"])
        XCTAssertEqual(saved.currentTime, 1.5, accuracy: 0.1)
    }

    func testASaveInTheMiddleOfShuttingDownCannotReplaceThePosition() async throws {
        let hook = TeardownHook()
        let session = try QuitSession(playerFactory: {
            DismantlingProbePlayer(item: $0, hook: hook)
        })
        try await session.loadPaused(at: 1.5)

        // A player whose item was just removed reports no time at all, which
        // reads as the start of the song. Saving at that moment is what an
        // asynchronous save can do on a busy machine, here made certain.
        hook.run = { [service = session.service] in service.applicationWillSleep() }
        session.service.shutdown()

        XCTAssertTrue(hook.didRun, "The player was never taken apart")
        let saved = try XCTUnwrap(session.savedState)
        XCTAssertEqual(saved.currentTime, 1.5, accuracy: 0.1)
        XCTAssertEqual(saved.userQueue.map(\.id), ["queued"])
    }

    func testStartingAgainAfterShuttingDownSavesAgain() async throws {
        let session = try QuitSession()
        try await session.loadPaused(at: 1.5)
        session.service.shutdown()

        session.service.start()
        session.service.addToUserQueue(songs: [makeSong("later")], position: "last")
        _ = session.service.fullState()
        try await Task.sleep(for: .milliseconds(800))

        let saved = try XCTUnwrap(session.savedState)
        XCTAssertEqual(saved.userQueue.map(\.id), ["queued", "later"])
        XCTAssertEqual(saved.currentTime, 1.5, accuracy: 0.1)
    }

    func testQuittingWithNothingLoadedSavesNothing() async throws {
        let session = try QuitSession()
        session.service.start()

        session.service.applicationWillTerminate()
        try await session.letTheServiceFinishSaving()

        XCTAssertNil(session.savedState)
    }

    func testARelaunchRestoresTheQueueAndWhereTheSongWas() async throws {
        let session = try QuitSession()
        try await session.loadPaused(at: 1.5)
        session.service.applicationWillTerminate()
        try await session.letTheServiceFinishSaving()

        let relaunched = session.relaunch()
        relaunched.start()

        let snapshot = relaunched.playbackSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.currentTime, 1.5, accuracy: 0.1)
        XCTAssertEqual(snapshot.metadata.title, "Song tone")
        XCTAssertEqual(snapshot.queue?.currentSongId, "tone")
        XCTAssertEqual(snapshot.queue?.contextSongs.map(\.id), ["tone"])
        XCTAssertEqual(snapshot.queue?.userQueue.map(\.id), ["queued"])
        XCTAssertEqual(snapshot.queue?.isRestored, true)
    }

    func testQuittingAgainBeforePlayingKeepsTheRestoredPosition() async throws {
        let session = try QuitSession()
        try await session.loadPaused(at: 1.5)
        session.service.applicationWillTerminate()
        try await session.letTheServiceFinishSaving()
        let relaunched = session.relaunch()
        relaunched.start()

        // Opened and closed without a single play: nothing has moved.
        relaunched.applicationWillTerminate()
        try await session.letTheServiceFinishSaving()

        let saved = try XCTUnwrap(session.savedState)
        XCTAssertEqual(saved.currentTime, 1.5, accuracy: 0.1)
        XCTAssertEqual(saved.contextSongs.map(\.id), ["tone"])
    }

    func testSleepingWritesTheSamePositionAQuitWould() async throws {
        let session = try QuitSession()
        try await session.loadPaused(at: 1.5)

        session.service.applicationWillSleep()

        // On disk before the call returned, with no waiting for a timer.
        let saved = try XCTUnwrap(session.savedState)
        XCTAssertEqual(saved.currentTime, 1.5, accuracy: 0.1)
    }
}

// MARK: - Fixture

/// A service over a temporary database holding one silent song and a queued
/// one, and the means to start another over the same database afterwards.
@MainActor
private final class QuitSession {
    let service: AudioService
    private let database: TemporaryDatabase
    private let song: QueueSong
    private var relaunched: [AudioService] = []

    init(
        playerFactory: @escaping AudioService.PlayerFactory = { AVQueuePlayer(items: [$0]) }
    ) throws {
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
        service = QuitSession.makeService(on: database, playerFactory: playerFactory)
    }

    deinit {
        service.shutdown()
        for other in relaunched { other.shutdown() }
    }

    private static func makeService(
        on database: TemporaryDatabase,
        playerFactory: @escaping AudioService.PlayerFactory = { AVQueuePlayer(items: [$0]) }
    ) -> AudioService {
        AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            playerFactory: playerFactory
        )
    }

    /// What a relaunch would restore.
    var savedState: PlaybackPersistState? {
        PlaybackStateRepository(db: database.manager.dbPool).load()
    }

    /// Another process over the same database, as a relaunch has.
    func relaunch() -> AudioService {
        let other = QuitSession.makeService(on: database)
        relaunched.append(other)
        return other
    }

    /// Loads the song and a queued one without playing, and seeks to a position.
    func loadPaused(at position: Double) async throws {
        service.start()
        service.setContextQueue(songs: [song], currentIndex: 0, autoplay: false)
        service.addToUserQueue(songs: [makeSong("queued")], position: "last")
        // Waits for the edits above, which run on the queue's own thread.
        _ = service.fullState()
        let loaded = await waitForPlayerStoreTest(timeout: .seconds(5)) { [service] in
            let snapshot = service.playbackSnapshot()
            return snapshot.state == .paused && snapshot.duration > 0
        }
        XCTAssertTrue(loaded, "The song never finished loading")
        await withCheckedContinuation { continuation in
            service.seek(to: position) { continuation.resume() }
        }
        XCTAssertEqual(service.playbackSnapshot().currentTime, position, accuracy: 0.1)
    }

    /// A quitting service saves once more on its own queue after the player is
    /// gone. Give that save time to land, so a late write cannot hide.
    func letTheServiceFinishSaving() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

// MARK: - Probe player

/// What runs when the probe player has had its items removed, which is the
/// moment `AudioService` takes its player apart.
private final class TeardownHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var ran = false

    var run: (() -> Void)? {
        get { lock.withLock { action } }
        set { lock.withLock { action = newValue } }
    }

    var didRun: Bool { lock.withLock { ran } }

    func fire() {
        let action = lock.withLock { () -> (() -> Void)? in
            guard self.action != nil else { return nil }
            ran = true
            return self.action
        }
        action?()
    }
}

/// A real player that lets a test act while it is empty but still owned by
/// the service, the state in which it reports no time.
private final class DismantlingProbePlayer: AVQueuePlayer {
    // Optional, so that the subclass declares no designated initializer and
    // inherits them all: AVQueuePlayer's own `init(items:)` calls `init()`.
    private var hook: TeardownHook?

    convenience init(item: AVPlayerItem, hook: TeardownHook) {
        self.init(items: [item])
        self.hook = hook
    }

    override func removeAllItems() {
        super.removeAllItems()
        hook?.fire()
    }
}
