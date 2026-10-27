import XCTest
@testable import AonsokuKit

final class DownloadTests: XCTestCase {
    func testTailnetSessionsWithCollidingTaskIDsKeepIndependentState() async throws {
        let fixture = try DownloadSchedulingFixture(tailscale: true)
        defer { fixture.manager.cancelAll(); fixture.session.invalidateAndCancel() }
        try fixture.setLimit(1)
        fixture.manager.download(songId: "tailnet-one")
        fixture.manager.download(songId: "tailnet-two")
        let tasks = try await fixture.waitForTasks(total: 2, running: 1)
        XCTAssertEqual(tasks[0].taskIdentifier, tasks[1].taskIdentifier)
        XCTAssertEqual(fixture.manager.activeDownloadSongIds, ["tailnet-one", "tailnet-two"])
        XCTAssertEqual(Set(fixture.persistedSongIds), ["tailnet-one", "tailnet-two"])
        fixture.manager.cancel(songId: "tailnet-one")
        XCTAssertEqual(fixture.manager.activeDownloadSongIds, ["tailnet-two"])
        XCTAssertEqual(tasks[1].state, .running)
        XCTAssertEqual(fixture.persistedSongIds, ["tailnet-two"])
    }

    func testTailnetPreparationCancellationCannotResurrectDownload() async throws {
        let fixture = try DownloadSchedulingFixture(tailscale: true, preparationDelay: .milliseconds(200))
        defer { fixture.manager.cancelAll(); fixture.session.invalidateAndCancel() }
        let spy = DownloadDelegateSpy()
        fixture.manager.delegate = spy
        fixture.manager.download(songId: "preparing")
        XCTAssertEqual(fixture.manager.activeDownloadSongIds, ["preparing"])
        XCTAssertEqual(fixture.persistedSongIds, ["preparing"])
        fixture.manager.cancel(songId: "preparing")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(fixture.manager.downloadTasksSnapshot.isEmpty)
        XCTAssertTrue(fixture.persistedSongIds.isEmpty)
        XCTAssertTrue(spy.failedSongIds.isEmpty)
    }

    func testCacheIdentityIsPathSafeAndStable() {
        let id = AudioCacheUtils.cacheId(for: "folder/song+=")

        XCTAssertEqual(id, AudioCacheUtils.cacheId(for: "folder/song+="))
        XCTAssertFalse(id.contains("/"))
        XCTAssertFalse(id.contains("+"))
        XCTAssertFalse(id.contains("="))
    }

    func testContentTypeSelectsExpectedFileExtension() {
        XCTAssertEqual(AudioCacheUtils.fileExtension(for: "audio/flac; charset=binary"), "flac")
        XCTAssertEqual(AudioCacheUtils.fileExtension(for: "audio/mpeg"), "mp3")
        XCTAssertEqual(AudioCacheUtils.fileExtension(for: "application/octet-stream"), "audio")
    }

    func testBackgroundSessionIdentifierIsStable() {
        XCTAssertEqual(
            NativeDownloadManager.backgroundSessionIdentifier,
            "github.realtvop.aonsoku.audio.downloads"
        )
    }

    func testDownloadURLCarriesAuthenticationAndTranscodingOptions() throws {
        let manager = makeManager()
        let credentials = ServerCredentials(
            serverUrl: "https://music.example/",
            username: "alice",
            password: "token",
            authType: "token",
            protocolVersion: "1.16.0",
            serverType: "navidrome",
            fallbackUrl: nil
        )
        let url = try XCTUnwrap(manager.buildDownloadURL(
            songId: "song 1",
            credentials: credentials,
            maxBitRate: 320,
            format: "mp3"
        ))
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                item in item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.path, "/rest/stream")
        XCTAssertEqual(query["id"], "song 1")
        XCTAssertEqual(query["maxBitRate"], "320")
        XCTAssertEqual(query["format"], "mp3")
        XCTAssertEqual(query["estimateContentLength"], "true")
    }

    func testMissingCredentialsFailsBeforeCreatingNetworkSession() {
        var sessionCreations = 0
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                sessionCreations += 1
                return URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: { nil }
        )
        let delegate = DownloadDelegateSpy()
        manager.delegate = delegate

        manager.download(songId: "song-1")

        XCTAssertEqual(sessionCreations, 0)
        XCTAssertEqual(delegate.failedSongIds, ["song-1"])
    }

    func testBackgroundRelaunchCompletionIsOwnedOnlyForMatchingIdentifier() {
        var session: URLSession?
        let manager = NativeDownloadManager(sessionFactory: { delegate in
            let created = URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
            session = created
            return created
        })
        XCTAssertFalse(manager.handleEvents(
            forBackgroundSession: "other.session",
            completionHandler: {}
        ))

        let completed = expectation(description: "background completion")
        XCTAssertTrue(manager.handleEvents(
            forBackgroundSession: NativeDownloadManager.backgroundSessionIdentifier,
            completionHandler: { completed.fulfill() }
        ))
        manager.urlSessionDidFinishEvents(
            forBackgroundURLSession: try! XCTUnwrap(session)
        )

        wait(for: [completed], timeout: 1)
    }

    func testActiveDownloadCancellationClearsTrackedTasksWithoutNetwork() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                URLSession(
                    configuration: configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: { self.credentials }
        )

        manager.download(songId: "one")
        manager.download(songId: "two")
        XCTAssertEqual(manager.activeDownloadSongIds, ["one", "two"])

        manager.cancel(songId: "one")
        XCTAssertEqual(manager.activeDownloadSongIds, ["two"])

        manager.cancelAll()
        XCTAssertEqual(manager.activeDownloadSongIds, [])
    }

    func testCancelledTaskCannotPublishLateCompletion() throws {
        let database = try TemporaryDatabase()
        let cache = database.directory.appendingPathComponent("audio-cache")
        var session: URLSession?
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                let created = URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
                session = created
                return created
            },
            cacheDirectoryProvider: { create in
                if create {
                    try FileManager.default.createDirectory(
                        at: cache,
                        withIntermediateDirectories: true
                    )
                }
                return cache
            }
        )
        let delegate = DownloadDelegateSpy()
        manager.delegate = delegate
        _ = manager.handleEvents(
            forBackgroundSession: NativeDownloadManager.backgroundSessionIdentifier,
            completionHandler: {}
        )
        let activeSession = try XCTUnwrap(session)
        let task = activeSession.downloadTask(
            with: URL(string: "https://example.test/song")!
        )
        task.taskDescription = "cancelled"
        manager.urlSession(
            activeSession,
            downloadTask: task,
            didWriteData: 1,
            totalBytesWritten: 1,
            totalBytesExpectedToWrite: 2
        )
        XCTAssertEqual(manager.activeDownloadSongIds, ["cancelled"])

        manager.cancel(songId: "cancelled")
        let download = database.directory.appendingPathComponent("download.tmp")
        try Data([1, 2, 3]).write(to: download)
        manager.urlSession(
            activeSession,
            downloadTask: task,
            didFinishDownloadingTo: download
        )

        XCTAssertTrue(delegate.completed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testCancelAllDoesNotCancelDownloadStartedAfterIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                URLSession(
                    configuration: configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: { self.credentials }
        )
        manager.download(songId: "old", requestId: "old-request")

        manager.cancelAll()
        manager.download(songId: "new", requestId: "new-request")

        for _ in 0 ..< 100 where manager.activeDownloadSongIds != ["new"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.activeDownloadSongIds, ["new"])
        manager.cancelAll()
    }

    func testCancelAllDropsDownloadThatBeganBeforeTaskSnapshot() async throws {
        let credentialsRequested = expectation(description: "credentials requested")
        let requestReturned = expectation(description: "download request returned")
        let releaseCredentials = DispatchSemaphore(value: 0)
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: {
                credentialsRequested.fulfill()
                releaseCredentials.wait()
                return self.credentials
            }
        )

        DispatchQueue.global().async {
            manager.download(songId: "old", requestId: "old-request")
            requestReturned.fulfill()
        }
        await fulfillment(of: [credentialsRequested], timeout: 1)

        manager.cancelAll()
        for _ in 0 ..< 100 where manager.isCancellingDownloads {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(manager.isCancellingDownloads)

        releaseCredentials.signal()
        await fulfillment(of: [requestReturned], timeout: 1)
        XCTAssertEqual(manager.activeDownloadSongIds, [])
    }

    func testSingleCancelDropsDeferredDownloadWhileItStarts() async throws {
        let credentialsRequested = expectation(description: "credentials requested")
        let releaseCredentials = DispatchSemaphore(value: 0)
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: {
                credentialsRequested.fulfill()
                releaseCredentials.wait()
                return self.credentials
            }
        )

        manager.cancelAll()
        manager.download(songId: "new", requestId: "new-request")
        await fulfillment(of: [credentialsRequested], timeout: 1)

        manager.cancel(songId: "new")
        releaseCredentials.signal()
        for _ in 0 ..< 100 where manager.activeDownloadSongIds.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.activeDownloadSongIds, [])
    }

    func testCompletedDownloadMovesFileWritesMetadataAndNotifiesDelegate() throws {
        let database = try TemporaryDatabase()
        let cache = database.directory.appendingPathComponent("audio-cache")
        var session: URLSession?
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                let created = URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
                session = created
                return created
            },
            cacheDirectoryProvider: { create in
                if create {
                    try FileManager.default.createDirectory(
                        at: cache,
                        withIntermediateDirectories: true
                    )
                }
                return cache
            },
            now: { Date(timeIntervalSince1970: 123) }
        )
        let delegate = DownloadDelegateSpy()
        manager.delegate = delegate
        _ = manager.handleEvents(
            forBackgroundSession: NativeDownloadManager.backgroundSessionIdentifier,
            completionHandler: {}
        )
        let activeSession = try XCTUnwrap(session)
        let task = activeSession.downloadTask(
            with: URL(string: "https://example.test/song")!
        )
        task.taskDescription = "{\"songId\":\"song-1\",\"requestId\":\"request-1\"}"
        let download = database.directory.appendingPathComponent("download.tmp")
        try Data([1, 2, 3]).write(to: download)

        manager.urlSession(
            activeSession,
            downloadTask: task,
            didFinishDownloadingTo: download
        )

        let completed = try XCTUnwrap(delegate.completed.first)
        XCTAssertEqual(completed.songId, "song-1")
        XCTAssertEqual(completed.requestId, "request-1")
        XCTAssertEqual(completed.contentType, "audio/mpeg")
        XCTAssertEqual(completed.sizeBytes, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.url.path))
        let metadataURL = cache.appendingPathComponent(
            "\(AudioCacheUtils.cacheId(for: "song-1")).json"
        )
        let metadata = try JSONDecoder().decode(
            NativeCachedAudioFileMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        XCTAssertEqual(metadata.songId, "song-1")
        XCTAssertEqual(metadata.lastModifiedAt, 123_000)
    }

    func testDefaultConcurrencyQueuesTracksAndCompletionFillsTheNextSlot() async throws {
        let fixture = try DownloadSchedulingFixture()
        defer { fixture.session.invalidateAndCancel() }
        for index in 1...5 { fixture.manager.download(songId: "song-\(index)") }
        let tasks = try await fixture.waitForTasks(total: 5, running: 2)
        XCTAssertEqual(tasks.map(\.state), [.running, .running, .suspended, .suspended, .suspended])
        XCTAssertEqual(fixture.persistedSongIds, ["song-3", "song-4", "song-5"])

        let file = fixture.database.directory.appendingPathComponent("complete.tmp")
        try Data([1, 2, 3]).write(to: file)
        fixture.manager.urlSession(
            fixture.session, downloadTask: try XCTUnwrap(tasks[0] as? URLSessionDownloadTask),
            didFinishDownloadingTo: file
        )
        XCTAssertEqual(tasks[2].state, .running)
        XCTAssertEqual(tasks[3].state, .suspended)
        XCTAssertEqual(fixture.persistedSongIds, ["song-4", "song-5"])
        // URLSession follows a successful download with a nil-error completion.
        // It must not free another slot or restart a finished request.
        fixture.manager.urlSession(fixture.session, task: tasks[0], didCompleteWithError: nil)
        XCTAssertEqual(tasks[3].state, .suspended)
    }

    func testAllConcurrencyOptionsBoundParallelRequests() async throws {
        for limit in [1, 2, 4, 8] {
            let fixture = try DownloadSchedulingFixture()
            defer { fixture.session.invalidateAndCancel() }
            try fixture.setLimit(limit)
            let manager = fixture.manager
            DispatchQueue.concurrentPerform(iterations: 12) { index in
                manager.download(songId: "song-\(index)")
            }
            let tasks = try await fixture.waitForTasks(total: 12, running: limit)
            XCTAssertEqual(tasks.filter { $0.state == .suspended }.count, 12 - limit)
        }
    }

    func testLimitChangesAndFailuresRefillWithoutInterruptingRunningTracks() async throws {
        let fixture = try DownloadSchedulingFixture()
        defer { fixture.session.invalidateAndCancel() }
        for index in 1...10 { fixture.manager.download(songId: "song-\(index)") }
        _ = try await fixture.waitForTasks(total: 10, running: 2)
        try fixture.setLimit(8)
        let tasks = try await fixture.waitForTasks(total: 10, running: 8)
        try fixture.setLimit(1)
        XCTAssertEqual(tasks.filter { $0.state == .running }.count, 8)

        for task in tasks.prefix(7) {
            fixture.fail(task)
            XCTAssertEqual(tasks[8].state, .suspended)
        }
        fixture.fail(tasks[7])
        XCTAssertEqual(tasks[8].state, .running)
        XCTAssertEqual(tasks[9].state, .suspended)
    }

    func testCancellingQueuedAndRunningTracksAndCancelAllAdvanceSafely() async throws {
        let fixture = try DownloadSchedulingFixture()
        defer { fixture.session.invalidateAndCancel() }
        try fixture.setLimit(1)
        for index in 1...4 { fixture.manager.download(songId: "song-\(index)") }
        let tasks = try await fixture.waitForTasks(total: 4, running: 1)
        fixture.manager.cancel(songId: "song-2")
        XCTAssertEqual(tasks[2].state, .suspended)
        fixture.manager.cancel(songId: "song-1")
        XCTAssertEqual(tasks[2].state, .running)
        XCTAssertEqual(tasks[3].state, .suspended)
        fixture.manager.cancelAll()
        fixture.manager.download(songId: "new")
        for _ in 0..<100 where fixture.manager.activeDownloadSongIds != ["new"] {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.manager.activeDownloadSongIds, ["new"])
        XCTAssertTrue(fixture.persistedSongIds.isEmpty)
        // Late progress for a cancelled waiting task cannot resurrect it.
        fixture.manager.urlSession(
            fixture.session, downloadTask: try XCTUnwrap(tasks[1] as? URLSessionDownloadTask),
            didWriteData: 1, totalBytesWritten: 1, totalBytesExpectedToWrite: 2
        )
        XCTAssertEqual(fixture.manager.activeDownloadSongIds, ["new"])
    }

    func testReconnectRecoversPersistedWaitingTracksBeforeAdmittingNewTracks() async throws {
        let fixture = try DownloadSchedulingFixture(restoredCount: 3)
        defer { fixture.session.invalidateAndCancel() }
        _ = try await fixture.waitForTasks(total: 3, running: 2)
        fixture.manager.download(songId: "new")
        let tasks = try await fixture.waitForTasks(total: 4, running: 2)
        XCTAssertEqual(tasks[2].state, .suspended)
        XCTAssertEqual(tasks[3].state, .suspended)
        XCTAssertEqual(fixture.persistedSongIds, ["restored-3", "new"])
        fixture.fail(tasks[0])
        XCTAssertEqual(tasks[2].state, .running)
        XCTAssertEqual(tasks[3].state, .suspended)
    }

    private func makeManager() -> NativeDownloadManager {
        NativeDownloadManager(sessionFactory: { delegate in
            URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
        })
    }

    private var credentials: ServerCredentials {
        ServerCredentials(
            serverUrl: "https://music.example",
            username: "alice",
            password: "token",
            authType: "token",
            protocolVersion: "1.16.0",
            serverType: "navidrome",
            fallbackUrl: nil
        )
    }
}

private final class DownloadSchedulingFixture {
    let database: TemporaryDatabase
    let preferences: PreferencesService
    let manager: NativeDownloadManager
    let session: URLSession

    init(restoredCount: Int = 0, tailscale: Bool = false, preparationDelay: Duration = .zero) throws {
        let database = try TemporaryDatabase()
        self.database = database
        preferences = PreferencesService(db: database.manager.dbPool)
        if restoredCount > 0 {
            let waiting: [[String: Any]] = (1...restoredCount).map { index in
                ["context": ["songId": "restored-\(index)", "requestId": "request-\(index)"],
                 "songCancellationGeneration": 0]
            }
            let data = try JSONSerialization.data(withJSONObject: waiting)
            preferences.setString(String(decoding: data, as: UTF8.self), for: NativeDownloadManager.downloadQueueStorageKey)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StallingURLProtocol.self]
        var createdSession: URLSession?
        manager = NativeDownloadManager(
            sessionFactory: { delegate in
                let created = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                createdSession = created
                return created
            },
            credentialsProvider: {
                ServerCredentials(
                    serverUrl: "https://example.test", username: "alice", password: "token",
                    authType: "token", protocolVersion: "1.16.0", serverType: "navidrome", fallbackUrl: nil
                )
            },
            estimateContentLengthProvider: { true },
            preferences: preferences,
            cacheDirectoryProvider: { _ in database.directory },
            routesThroughTailscale: { _ in tailscale },
            foregroundSessionFactory: { _, delegate in
                if preparationDelay > .zero { try await Task.sleep(for: preparationDelay) }
                return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            }
        )
        _ = manager.handleEvents(
            forBackgroundSession: NativeDownloadManager.backgroundSessionIdentifier,
            completionHandler: {}
        )
        session = try XCTUnwrap(createdSession)
    }

    func setLimit(_ value: Int) throws {
        var settings = AppSettings()
        settings.cache.downloadConcurrency = value
        try preferences.setJSON(settings, for: SettingsStore.storageKey)
    }

    var persistedSongIds: [String] {
        let queue = preferences.getJSON(
            NativeDownloadManager.downloadQueueStorageKey, as: [PersistedRequest].self
        ) ?? []
        return queue.map(\.context.songId)
    }

    private struct PersistedRequest: Decodable {
        struct Context: Decodable { let songId: String }
        let context: Context
    }

    func fail(_ task: URLSessionTask) {
        manager.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        task.cancel()
    }

    func waitForTasks(total: Int, running: Int) async throws -> [URLSessionTask] {
        var tasks: [URLSessionTask] = []
        for _ in 0..<100 {
            tasks = manager.downloadTasksSnapshot
            if tasks.count == total, tasks.filter({ $0.state == .running }).count == running { return tasks }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(total) tasks with \(running) running, got states \(tasks.map { $0.state.rawValue })")
        throw URLError(.timedOut)
    }
}

private final class DownloadDelegateSpy: NativeDownloadManagerDelegate {
    var failedSongIds: [String] = []
    var completed: [(
        songId: String,
        requestId: String?,
        url: URL,
        contentType: String,
        sizeBytes: Int64
    )] = []

    func downloadManager(
        _ manager: NativeDownloadManager,
        didProgress songId: String,
        requestId: String?,
        loaded: Int64,
        total: Int64
    ) {}

    func downloadManager(
        _ manager: NativeDownloadManager,
        didComplete songId: String,
        requestId: String?,
        fileUrl: URL,
        contentType: String,
        sizeBytes: Int64
    ) {
        completed.append((songId, requestId, fileUrl, contentType, sizeBytes))
    }

    func downloadManager(
        _ manager: NativeDownloadManager,
        didFail songId: String,
        requestId: String?,
        error: Error
    ) {
        failedSongIds.append(songId)
    }
}

private final class StallingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}
    override func stopLoading() {}
}
