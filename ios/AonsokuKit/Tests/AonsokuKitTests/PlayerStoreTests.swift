import AVFoundation
import Foundation
import XCTest

@testable import AonsokuKit

@MainActor
final class PlayerStoreTests: XCTestCase {
    func testQueueSnapshotMapsTiersIndexesSourceAndCurrentUser() {
        let context = [makeSong("a"), makeSong("b"), makeSong("c")]
        let users = [makeSong("u1"), makeSong("u2")]
        let regular = makePlayerSnapshot(
            context: context,
            currentIndex: 1,
            userQueue: users,
            source: AudioQueueSource(type: "album", id: "album-1")
        )

        let queue = PlayerStore.playerQueue(from: regular)
        XCTAssertEqual(queue.history.map(\.song.id), ["a"])
        XCTAssertEqual(queue.current?.song.id, "b")
        XCTAssertEqual(queue.current?.index, 1)
        XCTAssertEqual(queue.userQueue.map(\.song.id), ["u1", "u2"])
        XCTAssertEqual(queue.userQueue.map(\.index), [0, 1])
        XCTAssertEqual(queue.upNext.map(\.song.id), ["c"])
        XCTAssertEqual(queue.upNext.map(\.index), [2])
        XCTAssertEqual(queue.source, .album("album-1"))

        let playingUser = makePlayerSnapshot(
            context: context,
            currentIndex: 1,
            userQueue: users,
            isInUserQueue: true
        )
        let userQueue = PlayerStore.playerQueue(from: playingUser)
        XCTAssertEqual(userQueue.history.map(\.song.id), ["a", "b"])
        XCTAssertEqual(userQueue.current?.song.id, "u1")
        XCTAssertEqual(userQueue.current?.tier, .user)
        XCTAssertEqual(userQueue.userQueue.map(\.song.id), ["u2"])
        XCTAssertEqual(userQueue.userQueue.map(\.index), [1])
        XCTAssertEqual(userQueue.upNext.map(\.song.id), ["c"])
    }

    func testReplacementConfirmationCancelPlayNextReplaceAndStaleTarget() async throws {
        let fixture = try PlayerStoreTestFixture()
        let remote = PlayerRemoteSpy()
        remote.remoteNowPlaying = RemoteNowPlaying(
            deviceId: "remote-1",
            deviceName: "Living Room",
            song: mediaSong("current"),
            queue: PlayerQueue(
                current: QueueEntry(song: mediaSong("current"), tier: .context, index: 0),
                userQueue: [QueueEntry(song: mediaSong("queued"), tier: .user, index: 0)]
            ),
            isPlaying: true
        )
        let store = fixture.store(remote: remote)

        store.play([mediaSong("new-1"), mediaSong("new-2")], startingAt: 0)
        XCTAssertNotNil(store.pendingReplacement)
        XCTAssertEqual(store.pendingReplacement?.targetDeviceId, "remote-1")
        store.resolveReplacement(.cancel)
        XCTAssertNil(store.pendingReplacement)
        XCTAssertTrue(remote.commands.isEmpty)

        store.play([mediaSong("new-1"), mediaSong("new-2")], startingAt: 1)
        store.resolveReplacement(.playNext)
        let playedNext = await waitForPlayerStoreTest { remote.commands.count == 2 }
        XCTAssertTrue(playedNext)
        XCTAssertEqual(remote.commandTypes, ["add_to_queue_next", "next"])

        remote.commands = []
        store.play([mediaSong("replacement")])
        store.resolveReplacement(.replace)
        let replaced = await waitForPlayerStoreTest { remote.commands.count == 2 }
        XCTAssertTrue(replaced)
        XCTAssertEqual(remote.commandTypes, ["clear_queue", "play_at_index"])
        XCTAssertEqual(store.playbackStarts, 1)

        remote.commands = []
        store.play([mediaSong("stale")])
        XCTAssertNotNil(store.pendingReplacement)
        remote.remoteNowPlaying = nil
        store.resolveReplacement(.replace)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(remote.commands.isEmpty)
        XCTAssertEqual(store.playbackStarts, 1)
    }

    func testAlbumPlaylistArtistAndTransportRouteToRemote() async throws {
        let fixture = try PlayerStoreTestFixture()
        let albumSong = mediaSong("album-song")
        let playlistSong = mediaSong("playlist-song")
        let artistSong = mediaSong("artist-song")
        fixture.api.albumHandler = { id in
            if id == "artist-album" {
                return AlbumDetail(
                    album: Album(id: id, name: "Artist Album"),
                    songs: [artistSong]
                )
            }
            return AlbumDetail(album: Album(id: id, name: "Album"), songs: [albumSong])
        }
        fixture.api.playlistHandler = { id in
            PlaylistDetail(
                playlist: Playlist(id: id, name: "Playlist"),
                songs: [playlistSong]
            )
        }
        fixture.api.artistHandler = { id in
            ArtistDetail(
                artist: Artist(id: id, name: "Artist"),
                albums: [Album(id: "artist-album", name: "Artist Album")]
            )
        }
        let remote = PlayerRemoteSpy()
        remote.remoteNowPlaying = RemoteNowPlaying(
            deviceId: "remote-1",
            deviceName: "Living Room"
        )
        let store = fixture.store(remote: remote)

        await store.playAlbum(id: "album", startingAt: 0, shuffle: true)
        await store.playPlaylist(id: "playlist", startingAt: 0)
        await store.playArtist(id: "artist", name: "Artist", shuffle: true)
        let startedSelections = await waitForPlayerStoreTest { remote.commands.count == 4 }
        XCTAssertTrue(startedSelections)
        XCTAssertEqual(
            remote.commandTypes,
            ["play_album", "play_playlist", "play_at_index", "set_shuffle"]
        )
        XCTAssertEqual(store.playbackStarts, 3)

        remote.commands = []
        store.togglePlayPause()
        store.pause()
        store.next()
        store.previous()
        store.seek(to: 12)
        store.toggleShuffle()
        store.cycleRepeat()
        store.setVolume(2)
        let routedTransport = await waitForPlayerStoreTest { remote.commands.count == 8 }
        XCTAssertTrue(routedTransport)
        XCTAssertEqual(
            Set(remote.commandTypes),
            Set([
                "toggle_play_pause", "pause", "next", "previous", "seek",
                "set_shuffle", "set_repeat", "set_volume",
            ])
        )
        let volume = remote.commands.compactMap { $0.jsonObject["volume"] as? Double }.last
        XCTAssertEqual(volume, 1)
    }

    func testClearRejectsAnInFlightAlbumSelectionFromOldAccount() async throws {
        let fixture = try PlayerStoreTestFixture()
        let requested = expectation(description: "old album requested")
        let gate = PlayerSongGate()
        fixture.api.albumHandler = { id in
            requested.fulfill()
            await gate.wait()
            return AlbumDetail(
                album: Album(id: id, name: "Old album"),
                songs: [mediaSong("old-account-song")]
            )
        }
        let store = fixture.store()
        store.start()

        let selection = Task {
            await store.playAlbum(id: "old-account-album")
        }
        await fulfillment(of: [requested], timeout: 1)
        store.clearAll()
        await gate.open()
        await selection.value
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(store.hasMedia)
        XCTAssertEqual(store.playbackStarts, 0)
        XCTAssertNil(fixture.audio.fullState())
        fixture.audio.shutdown()
    }

    func testQueueNavigationRejectsAnInFlightAlbumSelection() async throws {
        let fixture = try PlayerStoreTestFixture()
        let requested = expectation(description: "album requested")
        let gate = PlayerSongGate()
        fixture.api.albumHandler = { id in
            requested.fulfill()
            await gate.wait()
            return AlbumDetail(
                album: Album(id: id, name: "Delayed album"),
                songs: [mediaSong("delayed-song")]
            )
        }
        fixture.audio.setContextQueue(
            songs: [fixture.queueSong("current"), fixture.queueSong("next")],
            currentIndex: 0,
            autoplay: false
        )
        let queueLoaded = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "current"
        }
        XCTAssertTrue(queueLoaded)
        let store = fixture.store()
        store.start()

        let selection = Task {
            await store.playAlbum(id: "delayed-album")
        }
        await fulfillment(of: [requested], timeout: 1)
        store.next()
        let navigated = await waitForPlayerStoreTest {
            store.localSong?.id == "next"
        }
        XCTAssertTrue(navigated)

        await gate.open()
        await selection.value
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.localSong?.id, "next")
        XCTAssertEqual(fixture.audio.fullState()?.currentSongId, "next")
        XCTAssertEqual(store.playbackStarts, 0)
        fixture.audio.shutdown()
    }

    func testRemoteQueueReorderSendsFlattenedProtocolIndexes() async throws {
        let fixture = try PlayerStoreTestFixture()
        let remote = PlayerRemoteSpy()
        remote.remoteNowPlaying = RemoteNowPlaying(
            deviceId: "remote-1",
            deviceName: "Living Room",
            song: mediaSong("b"),
            queue: PlayerQueue(
                history: [
                    QueueEntry(song: mediaSong("a"), tier: .context, index: 0)
                ],
                current: QueueEntry(song: mediaSong("b"), tier: .context, index: 1),
                userQueue: [
                    QueueEntry(song: mediaSong("u1"), tier: .user, index: 0),
                    QueueEntry(song: mediaSong("u2"), tier: .user, index: 1),
                ],
                upNext: [
                    QueueEntry(song: mediaSong("c"), tier: .context, index: 2),
                    QueueEntry(song: mediaSong("d"), tier: .context, index: 3),
                ]
            )
        )
        let store = fixture.store(remote: remote)

        store.move(in: .user, from: IndexSet(integer: 0), to: 2)
        store.move(in: .context, from: IndexSet(integer: 0), to: 2)

        let sent = await waitForPlayerStoreTest { remote.commands.count == 2 }
        XCTAssertTrue(sent)
        XCTAssertEqual(
            remote.commands.map(\.jsonObject).compactMap { object in
                guard let from = object["from"] as? Int,
                      let to = object["to"] as? Int else { return nil }
                return [from, to]
            },
            [[2, 3], [4, 5]]
        )
        fixture.audio.shutdown()
    }

    func testRemoteQueueExecutionCompletesAfterMutation() async throws {
        let fixture = try PlayerStoreTestFixture()
        try SongRepository(db: fixture.database.manager.dbPool).upsert(
            makeSongRecord("queued")
        )
        fixture.audio.setContextQueue(
            songs: [fixture.queueSong("current")],
            currentIndex: 0,
            autoplay: false
        )
        let loaded = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "current"
        }
        XCTAssertTrue(loaded)

        let succeeded = await withCheckedContinuation { continuation in
            XCTAssertTrue(fixture.audio.executeRemote(
                .addToQueue(songIds: ["queued"], position: "last")
            ) { result in
                continuation.resume(returning: result)
            })
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(fixture.audio.fullState()?.userQueue.map(\.id), ["queued"])
        fixture.audio.shutdown()
    }

    func testRemoteQueueResolutionPreservesOrderAndRejectsMissingSongs() async throws {
        let fixture = try PlayerStoreTestFixture()
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert([
            makeSongRecord("first"),
            makeSongRecord("second"),
        ])

        let added = await withCheckedContinuation { continuation in
            XCTAssertTrue(fixture.audio.executeRemote(
                .addToQueue(
                    songIds: ["second", "first", "second"],
                    position: "last"
                )
            ) { result in
                continuation.resume(returning: result)
            })
        }
        XCTAssertTrue(added)
        XCTAssertEqual(
            fixture.audio.fullState()?.userQueue.map(\.id),
            ["second", "first", "second"]
        )

        let rejected = await withCheckedContinuation { continuation in
            XCTAssertTrue(fixture.audio.executeRemote(
                .addToQueue(songIds: ["first", "missing"], position: "last")
            ) { result in
                continuation.resume(returning: result)
            })
        }
        XCTAssertFalse(rejected)
        XCTAssertEqual(
            fixture.audio.fullState()?.userQueue.map(\.id),
            ["second", "first", "second"]
        )
        fixture.audio.shutdown()
    }

    func testRemoteCommandsCompleteInSubmissionOrder() async throws {
        let fixture = try PlayerStoreTestFixture()
        try SongRepository(db: fixture.database.manager.dbPool).upsert(
            makeSongRecord("queued")
        )
        let completionOrder = LockedTestBox<[String]>([])
        let completed = expectation(description: "remote commands completed")
        completed.expectedFulfillmentCount = 2

        XCTAssertTrue(fixture.audio.executeRemote(
            .addToQueue(songIds: ["queued"], position: "last")
        ) { succeeded in
            XCTAssertTrue(succeeded)
            completionOrder.update { $0.append("add") }
            completed.fulfill()
        })
        XCTAssertTrue(fixture.audio.executeRemote(.clearQueue) { succeeded in
            XCTAssertTrue(succeeded)
            completionOrder.update { $0.append("clear") }
            completed.fulfill()
        })

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completionOrder.read { $0 }, ["add", "clear"])
        XCTAssertTrue(fixture.audio.fullState()?.userQueue.isEmpty == true)
        fixture.audio.shutdown()
    }

    func testClearRemovesQueueAndInvalidatesPendingRemoteCommands() async throws {
        let fixture = try PlayerStoreTestFixture()
        fixture.audio.setContextQueue(
            songs: [fixture.queueSong("old-account")],
            currentIndex: 0,
            autoplay: false
        )
        let loaded = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "old-account"
        }
        XCTAssertTrue(loaded)

        let completed = expectation(description: "remote command rejected")
        let result = LockedTestBox<Bool?>(nil)
        XCTAssertTrue(fixture.audio.executeRemote(.play) { succeeded in
            result.update { $0 = succeeded }
            completed.fulfill()
        })
        fixture.audio.clear()

        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(result.read { $0 }, false)
        XCTAssertNil(fixture.audio.fullState())
        fixture.audio.shutdown()
    }

    func testClearRejectsAnInFlightPlaybackSnapshot() async throws {
        let fixture = try PlayerStoreTestFixture()
        let started = expectation(description: "snapshot started")
        let release = DispatchSemaphore(value: 0)
        let shouldDelay = LockedTestBox(true)
        let audio = fixture.audio
        let oldSnapshot = AudioPlaybackSnapshot(
            state: .playing,
            currentTime: 12,
            duration: 180,
            bufferedTime: 30,
            metadata: AudioMetadata(title: "Old account"),
            queue: makePlayerSnapshot(
                context: [fixture.queueSong("old-account")],
                currentIndex: 0
            )
        )
        let store = PlayerStore(
            audio: fixture.audio,
            repository: fixture.repository,
            settings: fixture.settings,
            authentication: .shared,
            streamURL: { _ in nil },
            playbackSnapshot: {
                var delay = false
                shouldDelay.update {
                    delay = $0
                    $0 = false
                }
                if delay {
                    started.fulfill()
                    release.wait()
                    return oldSnapshot
                }
                return audio.playbackSnapshot()
            }
        )

        store.start()
        await fulfillment(of: [started], timeout: 1)
        store.clearAll()
        release.signal()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(store.hasMedia)
        XCTAssertTrue(store.queue.isEmpty)
        fixture.audio.shutdown()
    }

    func testLocalEnqueueMoveRemoveAndCoverReplayGainConversion() async throws {
        let fixture = try PlayerStoreTestFixture()
        fixture.settings.update { $0.playback.useAlbumCoverForSongs = true }
        let audio = fixture.audio
        audio.setContextQueue(
            songs: [fixture.queueSong("a"), fixture.queueSong("b"), fixture.queueSong("c")],
            currentIndex: 0,
            autoplay: false
        )
        let queueLoaded = await waitForPlayerStoreTest { audio.fullState() != nil }
        XCTAssertTrue(queueLoaded)
        let store = fixture.store()
        store.start()
        let storeStarted = await waitForPlayerStoreTest {
            store.localQueue.current?.song.id == "a"
        }
        XCTAssertTrue(storeStarted)

        let first = mediaSong(
            "u1",
            albumId: "album-u1",
            coverArt: "song-cover",
            replayGain: ReplayGainInfo(trackGain: -4, trackPeak: 0.8)
        )
        let second = mediaSong("u2")
        store.enqueue([first, second], position: .last)
        let enqueued = await waitForPlayerStoreTest { store.localQueue.userQueue.count == 2 }
        XCTAssertTrue(enqueued)
        var snapshot = try XCTUnwrap(audio.fullState())
        XCTAssertEqual(snapshot.userQueue.map(\.id), ["u1", "u2"])
        XCTAssertEqual(snapshot.userQueue.first?.coverArtId, "album-u1")
        XCTAssertEqual(snapshot.userQueue.first?.replayGain?.trackGain, -4)

        store.move(in: .user, from: IndexSet(integer: 0), to: 2)
        let movedUser = await waitForPlayerStoreTest {
            audio.fullState()?.userQueue.map(\.id) == ["u2", "u1"]
        }
        XCTAssertTrue(movedUser)

        store.move(in: .context, from: IndexSet(integer: 0), to: 2)
        let movedContext = await waitForPlayerStoreTest {
            audio.fullState()?.contextSongs.map(\.id) == ["a", "c", "b"]
        }
        XCTAssertTrue(movedContext)
        let refreshedMove = await waitForPlayerStoreTest {
            store.localQueue.upNext.first?.song.id == "c"
        }
        XCTAssertTrue(refreshedMove)
        store.remove(entries: [try XCTUnwrap(store.localQueue.upNext.first)])
        let removedContext = await waitForPlayerStoreTest {
            audio.fullState()?.contextSongs.map(\.id) == ["a", "b"]
        }
        XCTAssertTrue(removedContext)

        snapshot = try XCTUnwrap(audio.fullState())
        XCTAssertEqual(snapshot.currentSongId, "a")
        store.clearQueue()
        let cleared = await waitForPlayerStoreTest {
            let current = audio.fullState()
            return current?.contextSongs.map(\.id) == ["a"]
                && current?.userQueue.isEmpty == true
        }
        XCTAssertTrue(cleared)
        audio.shutdown()
    }

    func testStartEnrichesRestoredQueueSongsFromRepository() async throws {
        let fixture = try PlayerStoreTestFixture()
        try SongRepository(db: fixture.database.manager.dbPool).upsert(
            makeSongRecord("restored", title: "Enriched title")
        )
        fixture.audio.setContextQueue(
            songs: [
                QueueSong(
                    id: "restored",
                    title: "Restored title",
                    artist: "Artist",
                    album: "Album",
                    duration: 180,
                    streamUrl: "https://example.test/restored"
                )
            ],
            currentIndex: 0,
            autoplay: false
        )
        let restoredQueueLoaded = await waitForPlayerStoreTest {
            fixture.audio.fullState() != nil
        }
        XCTAssertTrue(restoredQueueLoaded)
        let store = fixture.store()
        store.start()

        let enriched = await waitForPlayerStoreTest {
            store.localSong?.title == "Enriched title"
        }
        XCTAssertTrue(enriched)
        XCTAssertEqual(store.localQueue.current?.song.title, "Enriched title")
        fixture.audio.shutdown()
    }

    func testClearRejectsInFlightSongEnrichmentFromOldAccount() async throws {
        let fixture = try PlayerStoreTestFixture()
        let enrichmentStarted = expectation(description: "old enrichment started")
        let gate = PlayerSongGate()
        let calls = LockedTestBox(0)
        fixture.api.songHandler = { id in
            calls.update { $0 += 1 }
            if calls.read({ $0 }) == 1 {
                enrichmentStarted.fulfill()
                await gate.wait()
                return Song(id: id, title: "Old enriched title")
            }
            return Song(id: id, title: "New enriched title")
        }
        fixture.audio.setContextQueue(
            songs: [QueueSong(
                id: "shared-id",
                title: "Old compact title",
                artist: "Old artist",
                album: "Old album",
                duration: 180,
                streamUrl: "https://example.test/old"
            )],
            currentIndex: 0,
            autoplay: false
        )
        let loaded = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "shared-id"
        }
        XCTAssertTrue(loaded)
        let store = fixture.store()
        store.start()
        await fulfillment(of: [enrichmentStarted], timeout: 1)

        store.clearAll()
        await gate.open()
        let cleared = await waitForPlayerStoreTest { !store.hasMedia }
        XCTAssertTrue(cleared)
        try? await Task.sleep(for: .milliseconds(20))

        fixture.audio.setContextQueue(
            songs: [QueueSong(
                id: "shared-id",
                title: "New compact title",
                artist: "New artist",
                album: "New album",
                duration: 180,
                streamUrl: "https://example.test/new"
            )],
            currentIndex: 0,
            autoplay: false
        )
        let enriched = await waitForPlayerStoreTest {
            store.localSong?.title == "New enriched title"
        }

        XCTAssertTrue(enriched)
        XCTAssertEqual(calls.read { $0 }, 2)
        fixture.audio.shutdown()
    }

    func testOverlappingEnrichmentsLookUpEachSharedSongOnce() async throws {
        let fixture = try PlayerStoreTestFixture()
        let gate = PlayerSongGate()
        let lookups = LockedTestBox<[String]>([])
        fixture.api.songHandler = { id in
            lookups.update { $0.append(id) }
            // Keeps the first lookup running while a second refresh starts.
            if id == "a" { await gate.wait() }
            return Song(id: id, title: "Enriched \(id)")
        }
        fixture.audio.setContextQueue(
            songs: [fixture.queueSong("a"), fixture.queueSong("b")],
            currentIndex: 0,
            autoplay: false
        )
        let loaded = await waitForPlayerStoreTest {
            fixture.audio.fullState()?.currentSongId == "a"
        }
        XCTAssertTrue(loaded)
        let store = fixture.store()
        store.start()
        let firstLookupRunning = await waitForPlayerStoreTest {
            lookups.read { $0.contains("a") }
        }
        XCTAssertTrue(firstLookupRunning)

        // The second refresh sees "a" and "b" again, still being looked up,
        // plus the newly queued "c". Only "c" may be fetched while "a" is
        // held open, so "c" showing up proves the shared ids were skipped.
        fixture.audio.addToUserQueue(
            songs: [fixture.queueSong("c")],
            position: "last"
        )
        let secondLookupRan = await waitForPlayerStoreTest {
            lookups.read { $0.contains("c") }
        }
        XCTAssertTrue(secondLookupRan)

        await gate.open()
        let enriched = await waitForPlayerStoreTest {
            store.localQueue.current?.song.title == "Enriched a"
                && store.localQueue.upNext.first?.song.title == "Enriched b"
                && store.localQueue.userQueue.first?.song.title == "Enriched c"
        }
        XCTAssertTrue(enriched)
        XCTAssertEqual(lookups.read { $0.sorted() }, ["a", "b", "c"])
        fixture.audio.shutdown()
    }

    func testStartAdoptsQueueRestoredAfterTheStoreSubscribes() async throws {
        let fixture = try PlayerStoreTestFixture()
        let engine = NativeQueueEngine()
        engine.setContextQueue(
            songs: [fixture.queueSong("restored-late")],
            currentIndex: 0,
            autoplay: false,
            startTime: nil
        )
        try PlaybackStateRepository(db: fixture.database.manager.dbPool).save(
            PlaybackPersistState(from: engine, currentTime: 42)
        )
        let store = fixture.store()

        // The SwiftUI composition root can subscribe before AppDelegate
        // starts AudioService. Restoration still has to reach that subscriber.
        store.start()
        fixture.audio.start()

        let restored = await waitForPlayerStoreTest {
            store.localSong?.id == "restored-late"
                && abs(store.localClock.position() - 42) < 0.1
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(store.localQueue.current?.song.id, "restored-late")
        fixture.audio.shutdown()
    }

    func testStartingPlaybackAdoptsTheNewQueueForTheUI() async throws {
        let fixture = try PlayerStoreTestFixture()
        let store = fixture.store()
        store.start()

        store.play(song: mediaSong("new-song"))

        let adopted = await waitForPlayerStoreTest {
            store.localSong?.id == "new-song"
                && store.localQueue.current?.song.id == "new-song"
        }
        XCTAssertTrue(adopted)
        fixture.audio.shutdown()
    }

    func testRadioWrapsWithoutCountingNavigationAndSleepTimerTracksState() throws {
        let fixture = try PlayerStoreTestFixture()
        let store = fixture.store()
        let stations = [
            RadioStation(id: "one", name: "One", streamUrl: "https://radio.test/one"),
            RadioStation(id: "two", name: "Two", streamUrl: "https://radio.test/two"),
        ]

        store.playRadio(stations, index: 1)
        XCTAssertEqual(store.radio?.current?.id, "two")
        XCTAssertEqual(store.playbackStarts, 1)
        store.next()
        XCTAssertEqual(store.radio?.current?.id, "one")
        store.previous()
        XCTAssertEqual(store.radio?.current?.id, "two")
        XCTAssertEqual(store.playbackStarts, 1)

        store.setSleepTimer(minutes: 5)
        guard case .countdown = store.sleepTimer else {
            return XCTFail("Expected a countdown timer")
        }
        store.setSleepTimerEndOfTrack()
        XCTAssertEqual(store.sleepTimer, .endOfTrack)
        store.cancelSleepTimer()
        XCTAssertEqual(store.sleepTimer, .off)
        fixture.audio.shutdown()
    }
}

@MainActor
final class PlayerStoreTestFixture {
    let database: TemporaryDatabase
    let api: FakeSubsonicAPI
    let repository: LibraryRepository
    let settings: SettingsStore
    let audio: AudioService

    init() throws {
        database = try TemporaryDatabase()
        api = FakeSubsonicAPI()
        repository = LibraryRepository(
            api: api,
            library: LibraryService(dbManager: database.manager),
            connectivity: FixedConnectivity()
        )
        settings = SettingsStore(
            preferences: PreferencesService(db: database.manager.dbPool)
        )
        audio = Self.buildAudio(database: database)
    }

    func makeAudio(
        playerFactory: @escaping AudioService.PlayerFactory = { AVPlayer(playerItem: $0) },
        recoveryController: PlaybackRecoveryController = PlaybackRecoveryController()
    ) -> AudioService {
        Self.buildAudio(
            database: database,
            playerFactory: playerFactory,
            recoveryController: recoveryController
        )
    }

    func store(remote: PlayerRemoteSpy? = nil) -> PlayerStore {
        let store = PlayerStore(
            audio: audio,
            repository: repository,
            settings: settings,
            authentication: .shared,
            streamURL: { URL(string: "https://example.test/stream/\($0)") }
        )
        store.remote = remote
        return store
    }

    func queueSong(_ id: String, replayGain: AudioReplayGain? = nil) -> QueueSong {
        QueueSong(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            album: "Album",
            duration: 180,
            streamUrl: "https://example.test/stream/\(id)",
            replayGain: replayGain
        )
    }

    private static func buildAudio(
        database: TemporaryDatabase,
        playerFactory: @escaping AudioService.PlayerFactory = { AVPlayer(playerItem: $0) },
        recoveryController: PlaybackRecoveryController = PlaybackRecoveryController()
    ) -> AudioService {
        let resolver = NativeSourceResolver(
            cacheDirectories: [database.directory],
            credentialsProvider: { nil }
        )
        let downloads = NativeDownloadManager(
            sessionFactory: { delegate in
                URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: { nil },
            cacheDirectoryProvider: { _ in database.directory }
        )
        return AudioService(
            databaseManager: database.manager,
            sourceResolver: resolver,
            downloadManager: downloads,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            recoveryController: recoveryController,
            playerFactory: playerFactory
        )
    }
}

@MainActor
final class PlayerRemoteSpy: RemotePlaybackSource {
    var remoteNowPlaying: RemoteNowPlaying?
    var commands: [CoordinationRemoteCommand] = []
    var error: Error?

    var commandTypes: [String] {
        commands.compactMap { $0.jsonObject["type"] as? String }
    }

    func send(_ command: CoordinationRemoteCommand) async throws {
        if let error { throw error }
        commands.append(command)
    }
}

private actor PlayerSongGate {
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

func makePlayerSnapshot(
    context: [QueueSong],
    currentIndex: Int,
    userQueue: [QueueSong] = [],
    isInUserQueue: Bool = false,
    source: AudioQueueSource? = nil
) -> AudioQueueSnapshot {
    AudioQueueSnapshot(
        contextSongs: context,
        currentIndex: currentIndex,
        sourceId: source,
        sourceName: "Source",
        userQueue: userQueue,
        originalContextSongs: [],
        originalUserSongs: [],
        shuffleHistory: [],
        shuffleStartHistory: [],
        playedUserQueueHistory: [],
        isInUserQueue: isInUserQueue,
        isShuffleActive: false,
        loopState: .off,
        isPlaying: false,
        currentTime: 0,
        duration: 180,
        currentSongId: isInUserQueue ? userQueue.first?.id : context[currentIndex].id,
        isRestored: false
    )
}

func mediaSong(
    _ id: String,
    albumId: String? = "album",
    coverArt: String? = nil,
    replayGain: ReplayGainInfo? = nil
) -> Song {
    Song(
        id: id,
        title: "Song \(id)",
        album: "Album",
        albumId: albumId,
        artist: "Artist",
        artistId: "artist",
        coverArt: coverArt,
        duration: 180,
        replayGain: replayGain
    )
}

@MainActor
func waitForPlayerStoreTest(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
