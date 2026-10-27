import XCTest

@testable import AonsokuKit

final class ServerURLFallbackTests: XCTestCase {
    private func config(active: String = "https://main.test/music") -> ServerURLFallback.Configuration {
        .init(credentials: ServerCredentials(
            serverUrl: active, username: "alice", password: "secret",
            authType: "password", protocolVersion: "1.16.0", serverType: "navidrome",
            fallbackUrl: "https://backup.test/proxy/music"
        ), primaryURL: "https://main.test/music")
    }

    private func request(_ endpoint: String = "getSong", host: String = "main.test") -> URLRequest {
        URLRequest(url: URL(string: "https://\(host)/music/rest/\(endpoint)?u=alice&p=secret&id=a%2Bb")!)
    }

    private func response(
        _ request: URLRequest, status: Int = 200,
        body: String = #"{"subsonic-response":{"status":"ok"}}"#
    ) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }

    func testTimeoutRetriesBackupPreservingBasePathAndEncodedQueryThenReusesIt() async throws {
        let state = LockedTestBox(config())
        let requests = LockedTestBox<[URLRequest]>([])
        let fallback = ServerURLFallback(configuration: { state.read { $0 } }, activate: { url, old in
            state.update { $0 = self.config(active: url) }
            XCTAssertEqual(old.primaryURL, "https://main.test/music")
        })
        let transport: HTTPClient.Transport = { request in
            requests.update { $0.append(request) }
            if request.url?.host == "main.test" { throw URLError(.timedOut) }
            return self.response(request)
        }
        _ = try await fallback.data(for: request(), transport: transport)
        _ = try await fallback.data(for: request(), transport: transport)
        let calls = requests.read { $0 }
        XCTAssertEqual(calls.map { $0.url?.host }, ["main.test", "backup.test", "backup.test"])
        XCTAssertEqual(calls[0].timeoutInterval, 10)
        XCTAssertEqual(calls[1].url?.path, "/proxy/music/rest/getSong")
        XCTAssertEqual(calls[1].url?.query, "u=alice&p=secret&id=a%2Bb")
        XCTAssertEqual(state.read { $0.credentials.serverUrl }, "https://backup.test/proxy/music")
    }

    func testUnavailableBackupCanReturnToPrimary() async throws {
        let state = config(active: "https://backup.test/proxy/music")
        let activated = LockedTestBox<String?>(nil)
        let fallback = ServerURLFallback(configuration: { state }, activate: { url, _ in
            activated.update { $0 = url }
        })
        _ = try await fallback.data(for: request()) { request in
            if request.url?.host == "backup.test" { throw URLError(.cannotConnectToHost) }
            XCTAssertEqual(request.url?.path, "/music/rest/getSong")
            return self.response(request)
        }
        XCTAssertEqual(activated.read { $0 }, state.primaryURL)
    }

    func testGatewayFailureRetriesReadButNotWrite() async throws {
        for endpoint in ["getSong", "createPlaylist"] {
            let state = config()
            let calls = LockedTestBox(0)
            let fallback = ServerURLFallback(configuration: { state }, activate: { _, _ in })
            _ = try await fallback.data(for: request(endpoint)) { request in
                calls.update { $0 += 1 }
                return self.response(request, status: request.url?.host == "main.test" ? 503 : 200)
            }
            XCTAssertEqual(calls.read { $0 }, endpoint == "getSong" ? 2 : 1)
        }
    }

    func testCancellationAndWriteTimeoutDoNotRetry() async {
        for (endpoint, code) in [("getSong", URLError.cancelled), ("createPlaylist", .timedOut)] {
            let state = config()
            let calls = LockedTestBox(0)
            let fallback = ServerURLFallback(configuration: { state }, activate: { _, _ in
                XCTFail("Must not activate a backup")
            })
            do {
                _ = try await fallback.data(for: request(endpoint)) { _ in
                    calls.update { $0 += 1 }
                    throw URLError(code)
                }
                XCTFail("Expected transport error")
            } catch {}
            XCTAssertEqual(calls.read { $0 }, 1)
        }
    }

    func testAuthenticationFailuresDoNotRetryOrActivate() async throws {
        let state = config()
        for status in [200, 401] {
            let calls = LockedTestBox(0)
            let fallback = ServerURLFallback(configuration: { state }, activate: { _, _ in
                XCTFail("Authentication failure must not change active server")
            })
            _ = try await fallback.data(for: request()) { request in
                calls.update { $0 += 1 }
                return self.response(request, status: status, body:
                    #"{"subsonic-response":{"status":"failed","error":{"code":40}}}"#)
            }
            XCTAssertEqual(calls.read { $0 }, 1)
        }
        let fallback = ServerURLFallback(configuration: { state }, activate: { _, _ in
            XCTFail("Backup's HTTP 200 auth failure must not activate it")
        })
        _ = try await fallback.data(for: request()) { request in
            if request.url?.host == "main.test" { throw URLError(.cannotConnectToHost) }
            return self.response(request, body: #"{"subsonic-response":{"status":"failed"}}"#)
        }
    }

    func testUnrelatedHostsAndUnsignedRequestsNeverReceiveFallback() async {
        let state = config()
        for request in [request(host: "external.test"), URLRequest(url: URL(string: "https://main.test/music/rest/getSong")!)] {
            let calls = LockedTestBox(0)
            let fallback = ServerURLFallback(configuration: { state }, activate: { _, _ in
                XCTFail("Unrelated requests must not change server")
            })
            do {
                _ = try await fallback.data(for: request) { _ in
                    calls.update { $0 += 1 }
                    throw URLError(.cannotConnectToHost)
                }
            } catch {}
            XCTAssertEqual(calls.read { $0 }, 1)
        }
    }

    func testSignOutWhilePrimaryFailsPreventsSendingCredentialsToBackup() async {
        let state = LockedTestBox<ServerURLFallback.Configuration?>(config())
        let calls = LockedTestBox(0)
        let fallback = ServerURLFallback(configuration: { state.read { $0 } }, activate: { _, _ in
            XCTFail("Signed-out account must not be restored")
        })
        do {
            _ = try await fallback.data(for: request()) { _ in
                calls.update { $0 += 1 }
                state.update { $0 = nil }
                throw URLError(.cannotConnectToHost)
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls.read { $0 }, 1)
    }
}
