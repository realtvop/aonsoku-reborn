import AVFoundation
import XCTest
@testable import AonsokuNativePlugin

final class NativeIntegrationTests: XCTestCase {
    func testAppServicesKeepsOneTypedServiceGraphAndLifecycle() throws {
        let database = try TemporaryDatabase()
        let audio = AudioService(databaseManager: database.manager)
        let library = LibraryService(dbManager: database.manager)
        var lifecycleEvents: [String] = []
        let lifecycle = AppLifecycleService(
            audio: AudioLifecycleActions(
                start: { lifecycleEvents.append("audio.start") },
                didEnterBackground: {
                    lifecycleEvents.append("audio.background")
                },
                willEnterForeground: {
                    lifecycleEvents.append("audio.foreground")
                },
                willTerminate: {
                    lifecycleEvents.append("audio.terminate")
                },
                handleBackgroundSession: { _, completion in
                    completion()
                    return true
                }
            ),
            coordination: CoordinationLifecycleActions(
                didEnterBackground: {
                    lifecycleEvents.append("coordination.background")
                },
                willEnterForeground: {
                    lifecycleEvents.append("coordination.foreground")
                },
                willTerminate: {
                    lifecycleEvents.append("coordination.terminate")
                }
            )
        )
        var factoryAudio: AudioService?

        let services = AppServices(
            audio: audio,
            library: library,
            lifecycleFactory: {
                factoryAudio = $0
                return lifecycle
            }
        )

        XCTAssertTrue(services.audio === audio)
        XCTAssertTrue(services.library === library)
        XCTAssertTrue(services.lifecycle === lifecycle)
        XCTAssertTrue(factoryAudio === audio)

        services.lifecycle.didFinishLaunching()
        services.lifecycle.didEnterBackground()
        services.lifecycle.willEnterForeground()
        services.lifecycle.didBecomeActive()
        services.lifecycle.willTerminate()
        XCTAssertEqual(lifecycleEvents, [
            "audio.start",
            "audio.background",
            "coordination.background",
            "audio.foreground",
            "coordination.foreground",
            "coordination.terminate",
            "audio.terminate",
        ])
    }

    func testAudioServicePersistsTypedQueueAndAdapterContract() throws {
        let database = try TemporaryDatabase()
        let fixtureURL = database.directory.appendingPathComponent("fixture.wav")
        try makeSilentWAVData().write(to: fixtureURL)
        let songs = ["a", "b"].map {
            QueueSong(
                id: $0,
                title: "Song \($0)",
                artist: "Artist",
                album: "Album",
                duration: 180,
                streamUrl: "aonsoku-media://stream?id=\($0)",
                cachedFileUri: fixtureURL.absoluteString
            )
        }
        var playerCreations = 0
        let playerCreated = expectation(description: "player created")
        let queueEvent = expectation(description: "queue event")
        let source = AudioService(
            databaseManager: database.manager,
            playerFactory: {
                playerCreations += 1
                playerCreated.fulfill()
                return AVPlayer(playerItem: $0)
            }
        )
        let eventToken = source.subscribe {
            if case .queueContentsChanged(let reason) = $0 {
                XCTAssertEqual(reason, "queue-edit")
                queueEvent.fulfill()
            }
        }

        source.start()
        source.setContextQueue(
            songs: songs,
            currentIndex: 1,
            sourceId: AudioQueueSource(type: "album", id: "album-1"),
            sourceName: "Album One",
            autoplay: false,
            repeatMode: .all
        )
        source.addToUserQueue(songs: [makeSong("queued")], position: "last")
        wait(for: [queueEvent, playerCreated], timeout: 2)
        guard let live = source.fullState() else {
            return XCTFail("expected live queue state")
        }
        XCTAssertEqual(live.currentSongId, "b")
        XCTAssertEqual(live.userQueue.map(\.id), ["queued"])
        XCTAssertEqual(playerCreations, 1)

        source.applicationWillTerminate()
        source.unsubscribe(eventToken)

        let restoredService = AudioService(databaseManager: database.manager)
        restoredService.start()
        guard let restored = restoredService.fullState() else {
            return XCTFail("expected restored queue state")
        }
        let payload = AonsokuNativeAudioPlugin.encodeQueueSnapshot(restored)
        let context = payload["contextQueue"] as? [String: Any]
        let encodedSongs = context?["songs"] as? [[String: Any]]

        XCTAssertEqual(restored.contextSongs.map(\.id), ["a", "b"])
        XCTAssertEqual(restored.currentSongId, "b")
        XCTAssertEqual(restored.userQueue.map(\.id), ["queued"])
        XCTAssertEqual(restored.loopState, .all)
        XCTAssertEqual(restored.sourceId, AudioQueueSource(type: "album", id: "album-1"))
        XCTAssertTrue(restored.isRestored)
        XCTAssertEqual(encodedSongs?.compactMap { $0["id"] as? String }, ["a", "b"])
        XCTAssertEqual(context?["sourceName"] as? String, "Album One")
        XCTAssertEqual(payload["loopState"] as? String, "all")
        restoredService.shutdown()
    }

    func testAudioServiceHandoffUsesInjectedLibraryAndRejectsMissingSongs() throws {
        let database = try TemporaryDatabase()
        try SongRepository(db: database.manager.dbPool).bulkUpsert([
            makeSongRecord("a"),
            makeSongRecord("b"),
            makeSongRecord("u"),
            makeSongRecord("old"),
        ])
        let cacheDirectory = database.directory.appendingPathComponent("cache")
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let cachedB = cacheDirectory.appendingPathComponent(
            "\(AudioCacheUtils.cacheId(for: "b")).wav"
        )
        try makeSilentWAVData().write(to: cachedB)
        let service = AudioService(
            databaseManager: database.manager,
            sourceResolver: NativeSourceResolver(
                cacheDirectories: [cacheDirectory],
                credentialsProvider: { nil }
            )
        )
        let accepted = expectation(description: "handoff accepted")
        var acceptedResult = false
        service.prepareHandoff(
            AudioHandoffSnapshot(
                songId: "b",
                progressSeconds: 12,
                contextQueue: ["a", "b"],
                contextIndex: 1,
                userQueue: ["u"],
                inUserQueue: false,
                restorePrevious: ["old"],
                shuffle: true,
                repeatMode: .all,
                sourceId: AudioQueueSource(type: "album", id: "album-1"),
                sourceName: "Album One",
                volume: nil
            ),
            autoplay: false
        ) {
            acceptedResult = $0
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)

        XCTAssertTrue(acceptedResult)
        XCTAssertEqual(service.fullState()?.contextSongs.map(\.id), ["a", "b"])
        XCTAssertEqual(service.fullState()?.userQueue.map(\.id), ["u"])
        XCTAssertEqual(
            service.fullState()?.playedUserQueueHistory.map(\.id),
            ["old"]
        )

        let rejected = expectation(description: "handoff rejected")
        var rejectedResult = true
        service.prepareHandoff(
            AudioHandoffSnapshot(
                songId: "missing",
                progressSeconds: 0,
                contextQueue: ["missing"],
                contextIndex: 0,
                userQueue: [],
                inUserQueue: false,
                restorePrevious: [],
                shuffle: false,
                repeatMode: .off,
                sourceId: nil,
                sourceName: nil,
                volume: nil
            ),
            autoplay: false
        ) {
            rejectedResult = $0
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        XCTAssertFalse(rejectedResult)
        service.clear()
    }

    func testLibraryServiceInitializationQueryAndCapacitorPageAdapter() throws {
        let database = try TemporaryDatabase()
        let service = LibraryService(dbManager: database.manager)
        XCTAssertEqual(
            service.initialize(startAutomaticSync: false),
            LibraryInitialization(ready: true, needsMigration: true)
        )
        try SongRepository(db: database.manager.dbPool).bulkUpsert([
            makeSongRecord("2", title: "Beta"),
            makeSongRecord("1", title: "Alpha"),
        ])
        try service.storeLyrics(songId: "1", content: "[00:01]Line", synced: true)

        let page = try service.songs(
            limit: 1,
            offset: 0,
            filter: LibrarySongFilter(sortBy: "title", sortOrder: "asc")
        )
        let payload = AonsokuNativeDataPlugin.pageDictionary(page)
        let items = payload["items"] as? [[String: Any]]

        XCTAssertEqual(page.total, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(items?.first?["id"] as? String, "1")
        XCTAssertEqual(items?.first?["title"] as? String, "Alpha")
        XCTAssertEqual(payload["total"] as? Int, 2)
        XCTAssertEqual(payload["hasMore"] as? Bool, true)
        XCTAssertEqual(try service.lyrics(songId: "1")?.content, "[00:01]Line")

        try SyncStateRepository(db: database.manager.dbPool).recordFullSync()
        let initialized = LibraryService(dbManager: database.manager)
            .initialize(startAutomaticSync: false)
        XCTAssertTrue(initialized.ready)
        XCTAssertFalse(initialized.needsMigration)
    }
}
