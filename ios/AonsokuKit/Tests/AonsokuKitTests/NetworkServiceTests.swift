import XCTest

@testable import AonsokuKit

final class NetworkServiceTests: XCTestCase {
    func testMissingPrivateRouteCanUseConfiguredBackupWithoutDirectPrivateAttempt() async throws {
        let state = LockedTestBox(fallbackConfiguration())
        let prepared = LockedTestBox<[String]>([])
        let direct = LockedTestBox<[String]>([])
        let fallback = ServerURLFallback(configuration: { state.read { $0 } }, activate: { address, _ in
            state.update { $0 = self.fallbackConfiguration(active: address) }
        })
        let network = NetworkService(prepareRoute: { url in
            prepared.update { $0.append(url.host!) }
            if url.host == "192.168.50.123" { throw TailscaleReadinessError.missingSubnetRoute(url.host!) }
            return false
        }, direct: { request, _ in
            direct.update { $0.append(request.url!.host!) }
            XCTAssertEqual(request.url?.host, "backup.test")
            return self.success(request)
        }, tailnet: { _, _ in
            XCTFail("Unready private target must not be dispatched"); throw URLError(.cannotConnectToHost)
        }, fallback: fallback)
        let request = signedRequest()
        _ = try await network.client(for: .subsonic).data(for: request)
        _ = try await network.client(for: .subsonic).data(for: request)
        XCTAssertEqual(prepared.read { $0 }, ["192.168.50.123", "backup.test", "backup.test"])
        XCTAssertEqual(direct.read { $0 }, ["backup.test", "backup.test"])
    }

    func testAlternatePrivateAddressRunsItsOwnReadinessAndTailnetTransport() async throws {
        let original = fallbackConfiguration(primary: "https://backup.test/proxy", backup: "http://192.168.50.123/music")
        let prepared = LockedTestBox<[String]>([])
        let routes = LockedTestBox<[String]>([])
        let network = NetworkService(prepareRoute: { url in
            prepared.update { $0.append(url.host!) }; return url.host == "192.168.50.123"
        }, direct: { request, _ in
            XCTAssertEqual(request.url?.host, "backup.test")
            routes.update { $0.append("direct") }; throw URLError(.timedOut)
        }, tailnet: { request, _ in
            XCTAssertEqual(request.url?.host, "192.168.50.123")
            routes.update { $0.append("tailscale") }; return self.success(request)
        }, fallback: ServerURLFallback(configuration: { original }, activate: { _, _ in }))
        _ = try await network.client().data(from: URL(string: "https://backup.test/proxy/rest/getGenres.view?u=alice&p=secret")!)
        XCTAssertEqual(prepared.read { $0 }, ["backup.test", "192.168.50.123"])
        XCTAssertEqual(routes.read { $0 }, ["direct", "tailscale"])
    }

    func testExactAddressPingAndReadinessAuthenticationFailuresDoNotUseBackup() async {
        for failure in [TailscaleReadinessError.loginRequired, .approvalRequired, .subnetRoutesDisabled,
                        .missingSubnetRoute("192.168.50.123")] {
            let config = fallbackConfiguration()
            let prepared = LockedTestBox<[String]>([])
            let network = NetworkService(prepareRoute: { url in
                prepared.update { $0.append(url.host!) }; throw failure
            }, direct: { _, _ in
                XCTFail("Not ready"); throw URLError(.cannotConnectToHost)
            }, tailnet: { _, _ in
                XCTFail("Not ready"); throw URLError(.cannotConnectToHost)
            }, fallback: ServerURLFallback(configuration: { config }, activate: { _, _ in
                XCTFail("Exact probe must not switch addresses")
            }))
            do {
                _ = try await network.client(for: .subsonic).data(for: signedRequest(endpoint: "ping.view"))
                XCTFail("Expected readiness failure")
            } catch { XCTAssertEqual(error as? TailscaleReadinessError, failure) }
            XCTAssertEqual(prepared.read { $0 }, ["192.168.50.123"])
            if failure != .missingSubnetRoute("192.168.50.123") {
                do {
                    _ = try await network.client().data(for: signedRequest())
                    XCTFail("Expected terminal authentication/configuration failure")
                } catch { XCTAssertEqual(error as? TailscaleReadinessError, failure) }
                XCTAssertEqual(prepared.read { $0 }, ["192.168.50.123", "192.168.50.123"])
            }
        }
    }

    private func fallbackConfiguration(active: String? = nil, primary: String = "http://192.168.50.123/music",
                                       backup: String = "https://backup.test/proxy") -> ServerURLFallback.Configuration {
        .init(credentials: ServerCredentials(serverUrl: active ?? primary, username: "alice", password: "secret",
                                             authType: "password", protocolVersion: "1.16.1", serverType: "navidrome",
                                             fallbackUrl: backup), primaryURL: primary)
    }

    private func signedRequest(endpoint: String = "getGenres.view") -> URLRequest {
        URLRequest(url: URL(string: "http://192.168.50.123/music/rest/\(endpoint)?u=alice&p=secret")!)
    }

    private func success(_ request: URLRequest) -> (Data, URLResponse) {
        (Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func testSyncDiagnosticsRecordActualRouteWithoutAuthenticatedQuery() async throws {
        let source = "SyncTest-\(UUID().uuidString)"
        let network = NetworkService(prepareRoute: { _ in true }, direct: { _, _ in
            XCTFail("Must use the chosen transport"); throw URLError(.cannotConnectToHost)
        }, tailnet: { request, _ in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await NetworkService.$diagnosticSource.withValue(source) {
            try await network.client().data(from: URL(string: "https://alice:secret@music.test/rest/getGenres.view?p=secret")!)
        }
        let entries = NativeLogger.shared.getEntries().filter { $0.source == source }
        XCTAssertTrue(entries.contains { $0.message.contains("getGenres.view route=tailscale elapsed=") })
        XCTAssertFalse(entries.contains { $0.message.contains("secret") || $0.message.contains("alice") })
    }

    func testSubsonicClientsReachSharedBoundaryWithSignedRequests() async throws {
        let calls = LockedTestBox<[(URLRequest, HTTPRequestProfile)]>([])
        let network = NetworkService { request, profile in
            calls.update { $0.append((request, profile)) }
            let data = Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8)
            return (data, HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!)
        }
        let credentials = ServerCredentials(
            serverUrl: "https://music.example", username: "alice", password: "secret",
            authType: "password", protocolVersion: "1.16.0", serverType: "navidrome",
            fallbackUrl: nil
        )
        _ = try await SubsonicHTTPClient(client: network.client(for: .subsonic)).request(
            baseUrl: credentials.serverUrl, path: "scrobble", credentials: credentials,
            extraQuery: ["id": "song-1"], method: "POST"
        )
        let api = AuthenticatedSubsonicTransport(
            urlBuilder: { _ in URL(string: "https://music.example/rest/getSong?u=alice") },
            client: network.client()
        )
        _ = try await api.send(SubsonicRequest("getSong", query: [
            URLQueryItem(name: "id", value: "song+1")
        ]))

        let requests = calls.read { $0 }
        XCTAssertEqual(requests.count, 2)
        guard requests.count == 2 else { return }
        XCTAssertEqual(requests[0].0.httpMethod, "POST")
        XCTAssertEqual(requests[0].0.url?.path, "/rest/scrobble")
        XCTAssertTrue(requests[0].0.url?.query?.contains("u=alice") == true)
        if case .subsonic = requests[0].1 {} else { XCTFail("Lost Subsonic policy") }
        XCTAssertTrue(requests[1].0.url?.absoluteString.contains("id=song%2B1") == true)
        if case .standard = requests[1].1 {} else { XCTFail("Lost standard policy") }
    }

    func testRequestAndResponseRemainIntactAcrossNetworkBoundary() async throws {
        let url = try XCTUnwrap(URL(string: "https://lyrics.example/search?title=A%2BB"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("body".utf8)
        request.setValue("custom-secret", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 17
        let expected = request
        let response = HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "12"]
        )!
        let network = NetworkService { request, profile in
            XCTAssertEqual(request, expected)
            if case .artwork = profile {} else { XCTFail("Lost artwork policy") }
            return (Data("retry".utf8), response)
        }

        let (data, result) = try await network.client(for: .artwork).data(for: request)

        XCTAssertEqual(data, Data("retry".utf8))
        XCTAssertEqual((result as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual((result as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "12")
    }

    func testCancellationDuringTransportDoesNotPublishResponse() async throws {
        let started = expectation(description: "Request reached transport")
        let release = LockedTestBox<CheckedContinuation<Void, Never>?>(nil)
        let client = HTTPClient { request in
            await withCheckedContinuation { continuation in
                release.update { $0 = continuation }
                started.fulfill()
            }
            return (Data(), URLResponse(
                url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil
            ))
        }
        let task = Task { try await client.data(from: URL(string: "https://music.example")!) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        release.read { $0 }?.resume()

        do {
            _ = try await task.value
            XCTFail("A cancelled request must not return stale data")
        } catch is CancellationError {
            // Injected transports can finish after cancellation, just like a
            // future connection setup operation. The boundary rejects that data.
        }
    }
}
