import AVFoundation
import XCTest
@testable import AonsokuKit

final class NativeIntegrationTests: XCTestCase {
    func testAppServicesKeepsOneTypedServiceGraphAndLifecycle() throws {
        let database = try TemporaryDatabase()
        let audio = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
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
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
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

        let restoredService = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
        )
        restoredService.start()
        guard let restored = restoredService.fullState() else {
            return XCTFail("expected restored queue state")
        }
        let payload = AudioPayloadCodec.encodeQueueSnapshot(restored)
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
            ),
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
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
        XCTAssertFalse(service.isAutomaticForegroundSyncEnabled)
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
        let payload = pageDictionary(page)
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

    func testAccountResetClearsServerDataButKeepsAppPreferences() throws {
        let database = try TemporaryDatabase()
        let service = LibraryService(dbManager: database.manager)
        let preferences = PreferencesService(db: database.manager.dbPool)
        try SongRepository(db: database.manager.dbPool).upsert(makeSongRecord("old"))
        try service.storeLyrics(songId: "old", content: "old lyrics", synced: true)
        try SyncStateRepository(db: database.manager.dbPool).recordFullSync()
        try preferences.addToPlayHistory(songJSON: "{}")
        preferences.setString("dark", for: "theme")

        try service.resetAccountData(clearCachedFiles: false)

        XCTAssertTrue(try service.songs().items.isEmpty)
        XCTAssertNil(try service.lyrics(songId: "old"))
        XCTAssertFalse(service.availability().available)
        XCTAssertTrue(try preferences.getPlayHistory().isEmpty)
        XCTAssertEqual(preferences.getString("theme"), "dark")
    }

    func testAccountDecisionAdoptsMatchingOwnersAndEmptyLibraries() {
        let alice = LibraryAccountIdentity(
            serverUrl: "https://one.test",
            username: "alice"
        )

        for explicitLogin in [true, false] {
            for hasLibraryData in [true, false] {
                XCTAssertEqual(
                    AppModel.accountSwitchDecision(
                        previous: alice,
                        next: alice,
                        hasLibraryData: hasLibraryData,
                        explicitLogin: explicitLogin
                    ),
                    .adopt
                )
            }
            XCTAssertEqual(
                AppModel.accountSwitchDecision(
                    previous: nil,
                    next: alice,
                    hasLibraryData: false,
                    explicitLogin: explicitLogin
                ),
                .adopt
            )
        }
    }

    func testAccountDecisionConfirmsAnUnknownOwnerOnlyForExplicitSignIn() {
        let alice = LibraryAccountIdentity(
            serverUrl: "https://one.test",
            username: "alice"
        )

        XCTAssertEqual(
            AppModel.accountSwitchDecision(
                previous: nil,
                next: alice,
                hasLibraryData: true,
                explicitLogin: true
            ),
            .confirm(.unknownOwner)
        )
        // Restoring at launch keeps adopting the library silently.
        XCTAssertEqual(
            AppModel.accountSwitchDecision(
                previous: nil,
                next: alice,
                hasLibraryData: true,
                explicitLogin: false
            ),
            .adopt
        )
    }

    func testAccountDecisionConfirmsAnotherServerOrAnotherUser() {
        let alice = LibraryAccountIdentity(
            serverUrl: "https://one.test",
            username: "alice"
        )

        for explicitLogin in [true, false] {
            for hasLibraryData in [true, false] {
                // The same user name at another address: keepable.
                XCTAssertEqual(
                    AppModel.accountSwitchDecision(
                        previous: alice,
                        next: LibraryAccountIdentity(
                            serverUrl: "https://two.test",
                            username: " alice "
                        ),
                        hasLibraryData: hasLibraryData,
                        explicitLogin: explicitLogin
                    ),
                    .confirm(.differentServer(previousServer: "https://one.test"))
                )
                // Another user, on the same server or another one.
                for server in ["https://one.test", "https://two.test"] {
                    XCTAssertEqual(
                        AppModel.accountSwitchDecision(
                            previous: alice,
                            next: LibraryAccountIdentity(
                                serverUrl: server,
                                username: "bob"
                            ),
                            hasLibraryData: hasLibraryData,
                            explicitLogin: explicitLogin
                        ),
                        .confirm(.differentAccount(
                            previousServer: "https://one.test",
                            previousUsername: "alice"
                        ))
                    )
                }
            }
        }
    }

    func testAccountDecisionTreatsEquivalentSpellingsAsTheSameOwner() {
        let owner = LibraryAccountIdentity(
            serverUrl: "https://Music.Example.com:443/",
            username: "Alice"
        )

        for server in [
            "https://music.example.com",
            "https://music.example.com:443",
            " https://music.example.com// ",
        ] {
            for username in ["Alice", " Alice ", "Alice\n"] {
                XCTAssertEqual(
                    AppModel.accountSwitchDecision(
                        previous: owner,
                        next: LibraryAccountIdentity(
                            serverUrl: server,
                            username: username
                        ),
                        hasLibraryData: true,
                        explicitLogin: true
                    ),
                    .adopt,
                    "\(server) / \(username)"
                )
            }
        }
    }

    func testAccountIdentityNormalizationKeepsWhatIdentifiesTheServer() {
        func identity(_ server: String, _ username: String = "alice") -> LibraryAccountIdentity {
            LibraryAccountIdentity(serverUrl: server, username: username)
        }
        let base = identity("https://music.example.com")

        XCTAssertEqual(base.normalizedServer, "https://music.example.com")
        XCTAssertEqual(
            identity("http://Music.Example.COM:80//").normalizedServer,
            "http://music.example.com"
        )
        XCTAssertEqual(
            identity("https://music.example.com:4533/Navidrome/").normalizedServer,
            "https://music.example.com:4533/Navidrome"
        )
        // A port that is the default for the other scheme still counts.
        XCTAssertFalse(base.isSameServer(as: identity("https://music.example.com:80")))
        XCTAssertFalse(base.isSameServer(as: identity("http://music.example.com:443")))
        XCTAssertFalse(base.isSameServer(as: identity("https://music.example.com:4533")))
        XCTAssertFalse(base.isSameServer(as: identity("https://other.example.com")))
        // The path is part of the address and keeps its case.
        XCTAssertFalse(base.isSameServer(as: identity("https://music.example.com/navidrome")))
        XCTAssertFalse(
            identity("https://music.example.com/Navidrome")
                .isSameServer(as: identity("https://music.example.com/navidrome"))
        )
        XCTAssertFalse(
            identity("https://music.example.com/navidrome")
                .isSameServer(as: identity("http://MUSIC.example.com/navidrome/"))
        )
        XCTAssertFalse(
            identity("a", " Alice ").isSameUsername(as: identity("b", "aLICE"))
        )
        XCTAssertFalse(
            identity("a", "alice").isSameUsername(as: identity("a", "alice2"))
        )
        // The synthesized Equatable still compares the stored strings.
        XCTAssertNotEqual(
            identity("https://music.example.com/", "Alice"),
            identity("https://music.example.com", "alice")
        )
        XCTAssertFalse(
            identity("https://music.example.com/", "Alice")
                .isSameAccount(as: identity("https://music.example.com", "alice"))
        )
    }
}
