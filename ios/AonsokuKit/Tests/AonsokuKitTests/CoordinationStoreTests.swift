import XCTest
@testable import AonsokuKit

@MainActor
final class CoordinationStoreTests: XCTestCase {
    func testGroupsDevicesAndResolvesSnapshotSongs() async throws {
        let fixture = try CoordinationStoreFixture()
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert([
            makeSongRecord("live"),
            makeSongRecord("offline"),
        ])
        let now = Date().timeIntervalSince1970
        let local = fixture.device("local")
        let live = fixture.device("live-device")
        let offline = fixture.device("offline-device")
        let stale = fixture.device("stale-device")
        let hidden = fixture.device("hidden-device", isControlling: true)
        fixture.store.handle(.stateChanged(CoordinationState(
            connectionState: .connected,
            deviceId: local.id,
            devices: [local, live, offline, stale, hidden],
            deviceSnapshots: [
                live.id: fixture.snapshot(live.id, songId: "live", isOnline: true),
                offline.id: fixture.snapshot(
                    offline.id,
                    songId: "offline",
                    isOnline: false,
                    lastConfirmedAt: now - 60
                ),
                stale.id: fixture.snapshot(
                    stale.id,
                    songId: "stale",
                    isOnline: false,
                    lastConfirmedAt: now - DeviceGroups.offlineExpiry - 1
                ),
                hidden.id: fixture.snapshot(hidden.id, songId: "hidden", isOnline: true),
            ]
        )))

        await fixture.waitUntil {
            self.fixtureSongIds(fixture.store.groups).contains("live")
        }
        XCTAssertEqual(fixture.store.groups.thisDevice?.id, local.id)
        XCTAssertEqual(fixture.store.groups.live.map(\.id), [live.id])
        XCTAssertEqual(fixture.store.groups.live.first?.song?.id, "live")
        XCTAssertEqual(fixture.store.groups.offlineSnapshots.map(\.id), [offline.id])
        XCTAssertTrue(fixture.store.groups.offlineSnapshots[0].canContinueHere)
        XCTAssertEqual(Set(fixture.store.groups.hidden.map(\.id)), Set([stale.id, hidden.id]))
    }

    func testRemoteProjectionBuildsQueueClockAndStopsWhenOffline() async throws {
        let fixture = try CoordinationStoreFixture()
        try SongRepository(db: fixture.database.manager.dbPool).bulkUpsert(
            ["a", "b", "c", "u1", "u2"].map { makeSongRecord($0) }
        )
        let device = fixture.device("remote", name: "Living Room")
        let sampledAt = Date().timeIntervalSince1970 - 2
        let playback = CoordinationPlaybackSnapshot(
            sessionId: "session",
            songId: "u1",
            progressSeconds: 10,
            durationSeconds: 100,
            isPlaying: true,
            sampledAt: sampledAt,
            contextQueue: ["a", "b", "c"],
            contextIndex: 1,
            sourceId: "album:album-1",
            sourceName: "Album",
            userQueue: ["u1", "u2"],
            inUserQueue: true,
            shuffle: true,
            repeatMode: .all,
            volume: 0.4
        )
        let online = fixture.snapshot(device.id, playback: playback, isOnline: true)
        fixture.store.handle(.stateChanged(CoordinationState(
            connectionState: .connected,
            deviceId: "local",
            devices: [device],
            deviceSnapshots: [device.id: online],
            controlledDeviceId: device.id
        )))
        await fixture.waitUntil { fixture.store.remoteNowPlaying?.song?.id == "u1" }

        let remote = try XCTUnwrap(fixture.store.remoteNowPlaying)
        XCTAssertEqual(remote.deviceName, "Living Room")
        XCTAssertEqual(remote.queue.history.map(\.song.id), ["a", "b"])
        XCTAssertEqual(remote.queue.current?.song.id, "u1")
        XCTAssertEqual(remote.queue.userQueue.map(\.song.id), ["u2"])
        XCTAssertEqual(remote.queue.upNext.map(\.song.id), ["c"])
        XCTAssertEqual(remote.queue.source, .album("album-1"))
        XCTAssertEqual(remote.repeatMode, .all)
        XCTAssertEqual(remote.volume, 0.4)
        XCTAssertEqual(remote.clock.position(at: remote.clock.sampledAt + 2), 12, accuracy: 0.01)

        fixture.store.handle(.stateChanged(CoordinationState(
            connectionState: .connected,
            deviceId: "local",
            devices: [device],
            deviceSnapshots: [
                device.id: fixture.snapshot(device.id, playback: playback, isOnline: false),
            ],
            controlledDeviceId: device.id
        )))
        XCTAssertNil(fixture.store.remoteNowPlaying)
        XCTAssertNil(fixture.store.controlledDeviceId)
        XCTAssertEqual(
            fixture.toasts.current?.message,
            .key("settings.crossDevice.toast.exitRemoteControl")
        )
    }

    func testHandoffEventsUpdateStatusAndToasts() throws {
        let fixture = try CoordinationStoreFixture()
        fixture.store.handle(.handoffFailed(transactionId: "tx", code: "timeout"))
        XCTAssertEqual(fixture.store.handoffStatus, .failed(code: "timeout"))
        XCTAssertEqual(
            fixture.toasts.current?.message,
            .key("settings.crossDevice.toast.relayFailed", ["code": "timeout"])
        )

        fixture.store.handle(.handoffCommitted(
            transactionId: "tx",
            snapshot: CoordinationPlaybackSnapshot(sessionId: "s", songId: "song"),
            newGeneration: 2
        ))
        XCTAssertEqual(fixture.store.handoffStatus, .idle)
        XCTAssertEqual(
            fixture.toasts.current?.message,
            .key("settings.crossDevice.toast.relaySuccess")
        )
    }

    func testDisconnectEndsAHandoffThatCannotFinish() throws {
        let fixture = try CoordinationStoreFixture()
        fixture.store.handle(.handoffFailed(transactionId: "tx", code: "timeout"))
        XCTAssertEqual(fixture.store.handoffStatus, .failed(code: "timeout"))

        fixture.store.disconnect()

        XCTAssertEqual(fixture.store.handoffStatus, .idle)
    }

    func testCommandAcknowledgementErrorsAreThrownToThePlayer() {
        XCTAssertNoThrow(
            try CoordinationStore.requireSuccessfulCommand(.ok)
        )
        XCTAssertThrowsError(
            try CoordinationStore.requireSuccessfulCommand(
                .error(code: "execution_failed", reason: "queue changed")
            )
        ) { error in
            XCTAssertEqual(
                error as? CoordinationError,
                CoordinationError(code: "execution_failed", reason: "queue changed")
            )
        }
    }

    func testStopRejectsOldAccountSongResolutionAndClearsState() async throws {
        let api = FakeSubsonicAPI()
        let requested = expectation(description: "old song requested")
        let gate = CoordinationSongGate()
        let calls = LockedTestBox(0)
        api.songHandler = { id in
            calls.update { $0 += 1 }
            if calls.read({ $0 }) == 1 {
                requested.fulfill()
                await gate.wait()
                return Song(id: id, title: "Old account title")
            }
            return Song(id: id, title: "New account title")
        }
        let fixture = try CoordinationStoreFixture(api: api, isOnline: true)
        let device = fixture.device("remote")
        let oldState = CoordinationState(
            connectionState: .connected,
            deviceId: "local",
            devices: [device],
            deviceSnapshots: [
                device.id: fixture.snapshot(
                    device.id,
                    songId: "shared-song",
                    isOnline: true
                ),
            ]
        )
        fixture.store.handle(.stateChanged(oldState))
        await fulfillment(of: [requested], timeout: 1)

        fixture.store.stop()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(fixture.store.state, CoordinationState())
        XCTAssertEqual(fixture.store.groups, DeviceGroups())
        fixture.store.handle(.stateChanged(oldState))
        await fixture.waitUntil {
            fixture.store.groups.live.first?.song?.title == "New account title"
        }

        XCTAssertEqual(calls.read { $0 }, 2)
        XCTAssertEqual(
            fixture.store.groups.live.first?.song?.title,
            "New account title"
        )
    }

    private func fixtureSongIds(_ groups: DeviceGroups) -> [String] {
        groups.live.compactMap(\.song?.id) + groups.offlineSnapshots.compactMap(\.song?.id)
    }
}

@MainActor
private final class CoordinationStoreFixture {
    let database: TemporaryDatabase
    let api: FakeSubsonicAPI
    let library: LibraryService
    let store: CoordinationStore
    let toasts = ToastCenter()

    init(
        api: FakeSubsonicAPI = FakeSubsonicAPI(),
        isOnline: Bool = false
    ) throws {
        database = try TemporaryDatabase()
        self.api = api
        library = LibraryService(
            dbManager: database.manager,
            credentialsProvider: { nil }
        )
        let repository = LibraryRepository(
            api: api,
            library: library,
            connectivity: FixedConnectivity(isOnline: isOnline)
        )
        store = CoordinationStore(
            service: CoordinationService(credentials: { nil }),
            repository: repository
        )
        store.toasts = toasts
    }

    func device(
        _ id: String,
        name: String? = nil,
        isControlling: Bool = false
    ) -> CoordinationDevice {
        CoordinationDevice(
            id: id,
            name: name ?? id,
            platform: "ios",
            isControlling: isControlling
        )
    }

    func snapshot(
        _ deviceId: String,
        songId: String,
        isOnline: Bool,
        lastConfirmedAt: Double = Date().timeIntervalSince1970
    ) -> CoordinationDeviceSnapshot {
        snapshot(
            deviceId,
            playback: CoordinationPlaybackSnapshot(sessionId: "s", songId: songId),
            isOnline: isOnline,
            lastConfirmedAt: lastConfirmedAt
        )
    }

    func snapshot(
        _ deviceId: String,
        playback: CoordinationPlaybackSnapshot,
        isOnline: Bool,
        lastConfirmedAt: Double = Date().timeIntervalSince1970
    ) -> CoordinationDeviceSnapshot {
        CoordinationDeviceSnapshot(
            deviceId: deviceId,
            snapshot: playback,
            isOnline: isOnline,
            generation: 1,
            snapshotRevision: 1,
            serverTime: Date().timeIntervalSince1970,
            lastConfirmedAt: lastConfirmedAt
        )
    }

    func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor CoordinationSongGate {
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
