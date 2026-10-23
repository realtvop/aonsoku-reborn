import AVFoundation
import Foundation
import XCTest

@testable import AonsokuKit

/// Adding songs to the queue of an `AudioService` that has none.
@MainActor
final class AudioQueueAdditionTests: XCTestCase {
    func testRemoteAddToQueueWhileIdleLoadsTheFirstSongPaused() async throws {
        let fixture = try PlayerStoreTestFixture()
        let ids = ["first", "second", "third"]
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert(
            ids.map { makeSongRecord($0) }
        )
        try cacheSilentAudio(for: ids, in: fixture)
        let events = LockedTestBox<[String]>([])
        let token = fixture.audio.subscribe { event in
            if case .queueContentsChanged(let reason) = event {
                events.update { $0.append(reason) }
            }
        }
        let snapshots = LockedTestBox<[AudioPlaybackSnapshot]>([])
        let subscription = fixture.audio.observeState { snapshot in
            snapshots.update { $0.append(snapshot) }
        }
        XCTAssertNil(fixture.audio.fullState())

        let added = await withCheckedContinuation { continuation in
            XCTAssertTrue(fixture.audio.executeRemote(
                .addToQueue(songIds: ["second", "first", "third"], position: "last")
            ) { continuation.resume(returning: $0) })
        }

        XCTAssertTrue(added)
        await assertQueuedAndLoadedPaused(
            fixture.audio,
            userQueue: ["second", "first", "third"]
        )
        let published = await eventually {
            snapshots.read { $0.contains { $0.queue?.currentSongId == "second" } }
        }
        XCTAssertTrue(published, "state listeners should receive the new queue")
        XCTAssertEqual(events.read { $0 }, ["queue-edit"])

        subscription.cancel()
        fixture.audio.unsubscribe(token)
        fixture.audio.shutdown()
    }

    func testRemoteAddToQueueWhileIdleStillRejectsMissingSongsWholesale() async throws {
        let fixture = try PlayerStoreTestFixture()
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert([
            makeSongRecord("known"),
        ])

        let rejected = await withCheckedContinuation { continuation in
            XCTAssertTrue(fixture.audio.executeRemote(
                .addToQueue(songIds: ["known", "missing"], position: "last")
            ) { continuation.resume(returning: $0) })
        }

        XCTAssertFalse(rejected)
        XCTAssertNil(fixture.audio.fullState())
        fixture.audio.shutdown()
    }

    func testPublicAddToUserQueueWhileIdleLoadsTheFirstSongPaused() async throws {
        let fixture = try PlayerStoreTestFixture()
        let songs = try localSongs(["a", "b", "c"], in: fixture)
        fixture.audio.setRepeatMode(.all)

        fixture.audio.addToUserQueue(songs: songs, position: "next")

        await assertQueuedAndLoadedPaused(fixture.audio, userQueue: ["a", "b", "c"])
        XCTAssertEqual(fixture.audio.fullState()?.loopState, .all)
        fixture.audio.shutdown()
    }

    func testAddToUserQueueAfterClearStartsAFreshQueue() async throws {
        let fixture = try PlayerStoreTestFixture()
        let songs = try localSongs(["old-1", "old-2", "new"], in: fixture)
        fixture.audio.setContextQueue(
            songs: Array(songs.prefix(2)),
            currentIndex: 1,
            autoplay: false
        )
        // Let the first song finish loading so that nothing from it is still
        // pending when the queue is cleared.
        let loaded = await eventually {
            fixture.audio.fullState()?.currentSongId == "old-2"
                && fixture.audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(loaded)
        fixture.audio.clear()
        XCTAssertNil(fixture.audio.fullState())
        XCTAssertEqual(fixture.audio.playbackSnapshot().state, .idle)

        fixture.audio.addToUserQueue(songs: [songs[2]], position: "last")

        await assertQueuedAndLoadedPaused(fixture.audio, userQueue: ["new"])
        fixture.audio.shutdown()
    }

    func testAddToUserQueueWhileAnotherSourceIsLoadedReplacesItWithTheNewQueue() async throws {
        let fixture = try PlayerStoreTestFixture()
        let songs = try localSongs(["old", "new"], in: fixture)
        fixture.audio.setContextQueue(
            songs: [songs[0]],
            currentIndex: 0,
            autoplay: false
        )
        let queued = await eventually {
            fixture.audio.fullState()?.currentSongId == "old"
                && fixture.audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(queued)
        // Loading a single source (a radio station) leaves the earlier queue
        // in the engine but hides it: there is no snapshot.
        let stationURL = try localAudioURL(for: "station", in: fixture)
        let loaded = await withCheckedContinuation { continuation in
            fixture.audio.load(AudioLoadRequest(
                source: .nativeFile(uri: stationURL.absoluteString, songId: "station")
            )) { result in
                if case .success = result { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
            }
        }
        XCTAssertTrue(loaded)
        XCTAssertNil(fixture.audio.fullState())

        fixture.audio.addToUserQueue(songs: [songs[1]], position: "last")

        await assertQueuedAndLoadedPaused(fixture.audio, userQueue: ["new"])
        fixture.audio.shutdown()
    }

    func testAddWhileAQueueIsActiveOnlyAppends() async throws {
        let fixture = try PlayerStoreTestFixture()
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert([
            makeSongRecord("remote"),
        ])
        let songs = try localSongs(["a", "b", "u"], in: fixture)
        let playerCreations = LockedTestBox(0)
        let audio = fixture.makeAudio(playerFactory: { item in
            playerCreations.update { $0 += 1 }
            return AVPlayer(playerItem: item)
        })
        let events = LockedTestBox<[String]>([])
        let token = audio.subscribe { event in
            if case .queueContentsChanged(let reason) = event {
                events.update { $0.append(reason) }
            }
        }
        audio.setContextQueue(
            songs: [songs[0], songs[1]],
            currentIndex: 0,
            autoplay: false
        )
        let queued = await eventually {
            audio.fullState()?.currentSongId == "a"
                && audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(queued)

        audio.addToUserQueue(songs: [songs[2]], position: "last")
        let remoteAdded = await withCheckedContinuation { continuation in
            XCTAssertTrue(audio.executeRemote(
                .addToQueue(songIds: ["remote"], position: "next")
            ) { continuation.resume(returning: $0) })
        }

        XCTAssertTrue(remoteAdded)
        let queue = try XCTUnwrap(audio.fullState())
        XCTAssertEqual(queue.contextSongs.map(\.id), ["a", "b"])
        XCTAssertEqual(queue.currentSongId, "a")
        XCTAssertFalse(queue.isInUserQueue)
        XCTAssertEqual(queue.userQueue.map(\.id), ["remote", "u"])
        XCTAssertEqual(playerCreations.read { $0 }, 1)
        XCTAssertEqual(events.read { $0 }, ["queue-edit", "queue-edit"])
        audio.unsubscribe(token)
        audio.shutdown()
        fixture.audio.shutdown()
    }

    // MARK: Helpers

    /// The queue shows `ids` as the user queue with the first one current and
    /// loaded, not playing, and nothing else queued.
    private func assertQueuedAndLoadedPaused(
        _ audio: AudioService,
        userQueue ids: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard let queue = audio.fullState() else {
            return XCTFail("expected a queue snapshot", file: file, line: line)
        }
        XCTAssertEqual(queue.userQueue.map(\.id), ids, file: file, line: line)
        XCTAssertEqual(queue.currentSongId, ids.first, file: file, line: line)
        XCTAssertTrue(queue.isInUserQueue, file: file, line: line)
        XCTAssertTrue(queue.contextSongs.isEmpty, file: file, line: line)
        XCTAssertFalse(queue.isShuffleActive, file: file, line: line)
        XCTAssertFalse(queue.isRestored, file: file, line: line)
        let paused = await eventually {
            audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(paused, "the first song should be loaded paused", file: file, line: line)
        let snapshot = audio.playbackSnapshot()
        XCTAssertEqual(
            snapshot.metadata.title,
            ids.first.map { "Song \($0)" },
            file: file,
            line: line
        )
        XCTAssertEqual(snapshot.queue?.isPlaying, false, file: file, line: line)
    }
}

// MARK: - Repeat and shuffle

/// Repeat and shuffle changes while the player is paused, when no progress or
/// playback event would carry them to observers.
@MainActor
final class AudioModePublishingTests: XCTestCase {
    func testPausedRepeatChangeReachesEveryObserver() async throws {
        let fixture = try PlayerStoreTestFixture()
        let audio = fixture.audio
        try await startPausedQueue(["a", "b"], in: fixture)
        let snapshots = LockedTestBox<[AudioPlaybackSnapshot]>([])
        let subscription = audio.observeState { snapshot in
            snapshots.update { $0.append(snapshot) }
        }
        let reasons = LockedTestBox<[String]>([])
        let token = audio.subscribe { event in
            if case .queueContentsChanged(let reason) = event {
                reasons.update { $0.append(reason) }
            }
        }
        let notifications = LockedTestBox(0)
        // Runs on the posting thread; never use `queue: .main` here.
        let observer = NotificationCenter.default.addObserver(
            forName: .aonsokuAudioStateDidChange,
            object: audio,
            queue: nil
        ) { _ in notifications.update { $0 += 1 } }
        _ = audio.fullState()
        let notificationsBefore = notifications.read { $0 }

        audio.setRepeatMode(.all)

        let delivered = await eventually {
            snapshots.read { $0.last?.queue?.loopState == .all }
        }
        XCTAssertTrue(delivered, "state listeners should receive the new mode")
        XCTAssertEqual(reasons.read { $0 }, ["repeat"])
        XCTAssertGreaterThan(notifications.read { $0 }, notificationsBefore)
        XCTAssertEqual(audio.fullState()?.loopState, .all)

        // The mode in effect again: nothing changed, so nothing is published.
        audio.setRepeatMode(.all)
        _ = audio.fullState()
        XCTAssertEqual(reasons.read { $0 }, ["repeat"])

        NotificationCenter.default.removeObserver(observer)
        audio.unsubscribe(token)
        subscription.cancel()
        audio.shutdown()
    }

    func testRemoteRepeatAndShuffleCommandsArePublishedWhilePaused() async throws {
        let fixture = try PlayerStoreTestFixture()
        let audio = fixture.audio
        try await startPausedQueue(["a", "b", "c"], in: fixture)
        let reasons = LockedTestBox<[String]>([])
        let token = audio.subscribe { event in
            if case .queueContentsChanged(let reason) = event {
                reasons.update { $0.append(reason) }
            }
        }

        let repeated = await withCheckedContinuation { continuation in
            XCTAssertTrue(audio.executeRemote(.setRepeat(.one)) {
                continuation.resume(returning: $0)
            })
        }
        let shuffled = await withCheckedContinuation { continuation in
            XCTAssertTrue(audio.executeRemote(.setShuffle(true)) {
                continuation.resume(returning: $0)
            })
        }

        XCTAssertTrue(repeated)
        XCTAssertTrue(shuffled)
        XCTAssertEqual(reasons.read { $0 }, ["repeat", "shuffle"])
        XCTAssertEqual(audio.fullState()?.loopState, .one)
        XCTAssertEqual(audio.fullState()?.isShuffleActive, true)
        let latest = await eventually {
            let queue = audio.playbackSnapshot().queue
            return queue?.loopState == .one && queue?.isShuffleActive == true
        }
        XCTAssertTrue(latest)

        audio.unsubscribe(token)
        audio.shutdown()
    }

    func testCyclingRepeatWhilePausedWalksOffAllOneOff() async throws {
        let fixture = try PlayerStoreTestFixture()
        let store = fixture.store()
        store.start()
        try await startPausedQueue(["a", "b"], in: fixture)
        let adopted = await eventually { store.localSong?.id == "a" }
        XCTAssertTrue(adopted)
        XCTAssertEqual(store.repeatMode, .off)

        var seen: [AudioRepeatMode] = []
        for expected in [AudioRepeatMode.all, .one, .off] {
            store.cycleRepeat()
            let changed = await eventually { store.repeatMode == expected }
            XCTAssertTrue(changed, "repeat should become \(expected)")
            seen.append(store.repeatMode)
        }

        XCTAssertEqual(seen, [.all, .one, .off])
        XCTAssertEqual(fixture.audio.fullState()?.loopState, .off)
        fixture.audio.shutdown()
    }

    func testTogglingShuffleWhilePausedFollowsTheEngine() async throws {
        let fixture = try PlayerStoreTestFixture()
        let store = fixture.store()
        store.start()
        try await startPausedQueue(["a", "b", "c"], in: fixture)
        let adopted = await eventually { store.localSong?.id == "a" }
        XCTAssertTrue(adopted)
        XCTAssertFalse(store.isShuffleActive)

        store.toggleShuffle()
        let on = await eventually { store.isShuffleActive }
        XCTAssertTrue(on)
        store.toggleShuffle()
        let off = await eventually { !store.isShuffleActive }
        XCTAssertTrue(off)
        XCTAssertEqual(fixture.audio.fullState()?.isShuffleActive, false)
        fixture.audio.shutdown()
    }

    /// Loads `ids` as the context queue, paused on the first one, and waits
    /// until the player settles there.
    private func startPausedQueue(
        _ ids: [String],
        in fixture: PlayerStoreTestFixture
    ) async throws {
        fixture.audio.setContextQueue(
            songs: try localSongs(ids, in: fixture),
            currentIndex: 0,
            autoplay: false
        )
        let paused = await eventually {
            fixture.audio.fullState()?.currentSongId == ids.first
                && fixture.audio.playbackSnapshot().state == .paused
        }
        XCTAssertTrue(paused, "the queue should be loaded and paused")
    }
}

// MARK: - Shared helpers

/// Loading the first item keeps the main thread busy while the process starts
/// using AVFoundation for the first time. On a busy simulator that has taken
/// well over ten seconds, so the wait is generous; it only matters when a
/// test fails.
@MainActor
private func eventually(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    await waitForPlayerStoreTest(timeout: .seconds(60), condition: condition)
}

private func localAudioURL(
    for id: String,
    in fixture: PlayerStoreTestFixture
) throws -> URL {
    let url = fixture.database.directory.appendingPathComponent(
        "\(AudioCacheUtils.cacheId(for: id)).wav"
    )
    if !FileManager.default.fileExists(atPath: url.path) {
        try makeSilentWAVData().write(to: url)
    }
    return url
}

/// Writes silent audio where the fixture's source resolver looks for cached
/// songs, so ids from the library resolve to local files.
private func cacheSilentAudio(
    for ids: [String],
    in fixture: PlayerStoreTestFixture
) throws {
    for id in ids { _ = try localAudioURL(for: id, in: fixture) }
}

/// Queue songs that point at local silent audio.
private func localSongs(
    _ ids: [String],
    in fixture: PlayerStoreTestFixture
) throws -> [QueueSong] {
    try ids.map { id in
        QueueSong(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            album: "Album",
            duration: 180,
            streamUrl: "aonsoku-media://stream?id=\(id)",
            cachedFileUri: try localAudioURL(for: id, in: fixture).absoluteString
        )
    }
}
