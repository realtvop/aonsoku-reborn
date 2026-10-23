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

    /// Loading the first item can keep the main thread busy for a couple of
    /// seconds while the process starts using AVFoundation for the first time.
    private func eventually(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await waitForPlayerStoreTest(timeout: .seconds(15), condition: condition)
    }

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

    /// Writes silent audio where the fixture's source resolver looks for
    /// cached songs, so ids from the library resolve to local files.
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
}
