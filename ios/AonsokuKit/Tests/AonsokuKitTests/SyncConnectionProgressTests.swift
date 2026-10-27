import XCTest
@testable import AonsokuKit

final class SyncConnectionProgressTests: XCTestCase {
    func testActualSyncWaitsWithinFallbackAttemptThenContinuesOnBackup() async throws {
        let database = try TemporaryDatabase()
        let primary = "http://192.168.50.123/music"
        let backup = "https://backup.test/proxy"
        @Sendable func config(_ address: String) -> ServerURLFallback.Configuration {
            .init(credentials: ServerCredentials(serverUrl: address, username: "user", password: "secret",
                                                 authType: "password", protocolVersion: "1.16.1", serverType: "navidrome",
                                                 fallbackUrl: backup), primaryURL: primary)
        }
        let state = LockedTestBox(config(primary))
        let sent = LockedTestBox<[String]>([])
        let waiting = expectation(description: "Sync waits for actual request preparation")
        let entered = expectation(description: "Primary route preparation entered")
        let release = LockedTestBox<CheckedContinuation<Void, Never>?>(nil)
        let network = NetworkService(prepareRoute: { url in
            if url.host == "192.168.50.123" {
                await withCheckedContinuation { continuation in
                    release.update { $0 = continuation }; entered.fulfill()
                }
                throw TailscaleReadinessError.missingSubnetRoute(url.host!)
            }
            return false
        }, direct: { request, _ in
            sent.update { $0.append(request.url!.host!) }
            XCTAssertEqual(request.url?.host, "backup.test")
            return (Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, tailnet: { _, _ in
            XCTFail("Unready private URL must not be dispatched"); throw URLError(.cannotConnectToHost)
        }, fallback: ServerURLFallback(configuration: { state.read { $0 } }, activate: { address, _ in
            state.update { $0 = config(address) }
        }))
        let engine = SyncEngine(db: database.manager.dbPool,
                                httpClient: SubsonicHTTPClient(client: network.client(for: .subsonic)),
                                credentialsProvider: { state.read { $0.credentials } })
        let didPublish = LockedTestBox(false)
        engine.onSyncStateChanged = { value in
            if value["phase"] as? String == "connecting" {
                let first = didPublish.read { !$0 }
                didPublish.update { $0 = true }
                if first { waiting.fulfill() }
            }
        }
        let sync = Task { await engine.syncAllAndWait(includeFullSongs: false, mode: "full") }
        await fulfillment(of: [entered, waiting], timeout: 2)
        XCTAssertTrue(sent.read { $0.isEmpty })
        release.read { $0 }?.resume()
        let result = await sync.value
        XCTAssertTrue(result)
        XCTAssertEqual(state.read { $0.credentials.serverUrl }, backup)
        XCTAssertFalse(sent.read { $0.isEmpty })
        XCTAssertTrue(sent.read { $0.allSatisfy { $0 == "backup.test" } })
    }

    func testSyncWaitsForConnectionBeforeStartingEssentials() async throws {
        let database = try TemporaryDatabase()
        let requests = LockedTestBox<[String]>([])
        let entered = expectation(description: "Preparing connection")
        let visible = expectation(description: "Waiting phase published")
        let release = LockedTestBox<CheckedContinuation<Void, Error>?>(nil)
        let engine = SyncEngine(db: database.manager.dbPool, httpClient: ClosureSyncHTTPClient { path, _ in
            requests.update { $0.append(path) }; return SubsonicResponse(data: [:], count: 0)
        }, credentialsProvider: { Self.credentials }, prepareConnection: { _ in
            try await withCheckedThrowingContinuation { continuation in
                release.update { $0 = continuation }; entered.fulfill()
            }
        })
        engine.onSyncStateChanged = { state in
            if state["phase"] as? String == "connecting" { visible.fulfill() }
        }
        let sync = Task { await engine.syncAllAndWait(includeFullSongs: false, mode: "full") }
        await fulfillment(of: [entered, visible], timeout: 2)
        XCTAssertTrue(requests.read { $0.isEmpty })
        release.read { $0 }?.resume(returning: ())
        let success = await sync.value
        XCTAssertTrue(success)
        XCTAssertEqual(requests.read { $0.first }, "getGenres.view")
    }

    func testPlaylistTimeoutFailsPromptlyInsteadOfTimingOutEveryPlaylist() async throws {
        let database = try TemporaryDatabase()
        let requests = LockedTestBox<[String]>([])
        let failed = expectation(description: "Failure published")
        let message = LockedTestBox("")
        let engine = SyncEngine(db: database.manager.dbPool, httpClient: ClosureSyncHTTPClient { path, _ in
            requests.update { $0.append(path) }
            if path == "getPlaylists.view" { return Self.playlists(100) }
            if path == "getPlaylist.view" { throw SubsonicHTTPError.networkUnreachable("The request timed out.") }
            return SubsonicResponse(data: [:], count: 0)
        }, credentialsProvider: { Self.credentials })
        engine.onSyncStateChanged = { state in
            if state["phase"] as? String == "error" {
                message.update { $0 = state["message"] as? String ?? "" }; failed.fulfill()
            }
        }
        let result = await engine.syncAllAndWait(includeFullSongs: false, mode: "full")
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(result)
        XCTAssertEqual(requests.read { $0.filter { $0 == "getPlaylist.view" }.count }, 1)
        XCTAssertFalse(requests.read { $0.contains("getStarred2.view") })
        XCTAssertEqual(message.read { $0 }, "getPlaylist.view: The request timed out.")
    }

    func testPlaylistProgressUpdatesBeforeBatchCompletesAndCancellationStopsRequests() async throws {
        let database = try TemporaryDatabase()
        let requests = LockedTestBox(0)
        let progress = expectation(description: "First playlist progress published")
        let entered = expectation(description: "Second playlist is pending")
        let release = LockedTestBox<CheckedContinuation<Void, Never>?>(nil)
        let engine = SyncEngine(db: database.manager.dbPool, httpClient: ClosureSyncHTTPClient { path, _ in
            if path == "getPlaylists.view" { return Self.playlists(3) }
            if path == "getPlaylist.view" {
                requests.update { $0 += 1 }
                if requests.read({ $0 }) == 2 {
                    await withCheckedContinuation { continuation in
                        release.update { $0 = continuation }; entered.fulfill()
                    }
                    try Task.checkCancellation()
                }
            }
            return SubsonicResponse(data: [:], count: 0)
        }, credentialsProvider: { Self.credentials })
        engine.onSyncStateChanged = { state in
            if state["phase"] as? String == "playlists", state["processedItems"] as? Int == 1,
               state["totalItems"] as? Int == 3 { progress.fulfill() }
        }
        let sync = Task { await engine.syncAllAndWait(includeFullSongs: false, mode: "full") }
        await fulfillment(of: [entered, progress], timeout: 2)
        engine.cancel()
        release.read { $0 }?.resume()
        let result = await sync.value
        XCTAssertFalse(result)
        XCTAssertEqual(requests.read { $0 }, 2)
    }

    private static var credentials: ServerCredentials {
        ServerCredentials(serverUrl: "https://music.test", username: "user", password: "secret",
                          authType: "password", protocolVersion: "1.16.1", serverType: "navidrome", fallbackUrl: nil)
    }

    private static func playlists(_ count: Int) -> SubsonicResponse {
        SubsonicResponse(data: ["playlists": ["playlist": (0..<count).map { ["id": "\($0)", "name": "Playlist \($0)"] }]], count: count)
    }
}

private struct ClosureSyncHTTPClient: LibrarySyncHTTPClient {
    let handler: (String, [String: String]) async throws -> SubsonicResponse
    init(_ handler: @escaping (String, [String: String]) async throws -> SubsonicResponse) { self.handler = handler }
    func request(baseUrl: String, path: String, credentials: ServerCredentials,
                 extraQuery: [String: String], method: String) async throws -> SubsonicResponse {
        try await handler(path, extraQuery)
    }
}
