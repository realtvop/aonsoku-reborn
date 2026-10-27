import XCTest
@testable import AonsokuKit

final class HTTPClientTests: XCTestCase {
    func testCancelledSyncHTTPRequestsDoNotBecomeNetworkFailures() async {
        for failure: Error in [CancellationError(), URLError(.cancelled)] {
            let base = SubsonicHTTPClient(client: HTTPClient { _ in throw failure })
            let client = DiagnosticSyncHTTPClient(base: base)
            do {
                _ = try await client.request(baseUrl: credentials.serverUrl, path: "getGenres.view",
                                             credentials: credentials, extraQuery: [:], method: "GET")
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // SyncEngine must receive this type to publish cancelled.
            } catch {
                XCTFail("Cancellation became a sync failure: \(error)")
            }
        }
    }

    func testSyncFailureIncludesOperationAndHTTPStatusWithoutAuthenticatedURL() async {
        let base = SubsonicHTTPClient(client: HTTPClient { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        let client = DiagnosticSyncHTTPClient(base: base)
        do {
            _ = try await client.request(baseUrl: credentials.serverUrl, path: "getGenres.view?private=secret",
                                         credentials: credentials, extraQuery: [:], method: "GET")
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "getGenres.view: HTTP 503")
            XCTAssertFalse(error.localizedDescription.contains("alice"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testSyncFailurePreservesTransportReason() async {
        let base = SubsonicHTTPClient(client: HTTPClient { _ in throw URLError(.timedOut) })
        let client = DiagnosticSyncHTTPClient(base: base)
        do {
            _ = try await client.request(baseUrl: credentials.serverUrl, path: "search3.view",
                                         credentials: credentials, extraQuery: [:], method: "GET")
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error.localizedDescription, "search3.view: \(URLError(.timedOut).localizedDescription)")
        }
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testBuildURLPreservesPathQueryAndAddsEncodedAuthentication() throws {
        let client = SubsonicHTTPClient(session: makeSession())
        let url = try client.buildURL(
            baseUrl: "https://music.example/",
            path: "updatePlaylist?playlistId=1",
            credentials: credentials,
            extraQuery: ["name": "Road Songs"]
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                item in item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.path, "/rest/updatePlaylist")
        XCTAssertEqual(query["playlistId"], "1")
        XCTAssertEqual(query["u"], "alice")
        XCTAssertEqual(query["p"], "enc:736563726574")
        XCTAssertEqual(query["name"], "Road Songs")
    }

    func testRequestUsesInjectedSessionAndParsesCountAndPayload() async throws {
        var capturedURL: URL?
        URLProtocolStub.handler = { request in
            capturedURL = request.url
            let body = Data("""
                {"subsonic-response":{"status":"ok","version":"1.16.1"}}
                """.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["x-total-count": "3"]
            )!
            return (response, body)
        }
        let client = SubsonicHTTPClient(session: makeSession())

        let response = try await client.request(
            baseUrl: "https://music.example",
            path: "ping.view",
            credentials: credentials
        )

        XCTAssertEqual(response.count, 3)
        XCTAssertEqual(response.data["status"] as? String, "ok")
        XCTAssertEqual(capturedURL?.path, "/rest/ping.view")
    }

    func testRequestMapsSubsonicAuthFailureWithoutRealNetwork() async {
        URLProtocolStub.handler = { request in
            let body = Data("""
                {"subsonic-response":{"status":"failed","error":{"code":40,"message":"bad auth"}}}
                """.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        let client = SubsonicHTTPClient(session: makeSession())

        do {
            _ = try await client.request(
                baseUrl: "https://music.example",
                path: "ping.view",
                credentials: credentials
            )
            XCTFail("Expected authentication failure")
        } catch SubsonicHTTPError.authFailed(let message) {
            XCTAssertEqual(message, "bad auth")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestPreservesProtocolVersionFromIncompatibleResponse() async {
        URLProtocolStub.handler = { request in
            let body = Data("""
                {"subsonic-response":{"status":"failed","version":"1.14.0","error":{"code":30,"message":"upgrade client"}}}
                """.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        let client = SubsonicHTTPClient(session: makeSession())

        do {
            _ = try await client.request(
                baseUrl: "https://music.example",
                path: "ping.view",
                credentials: credentials
            )
            XCTFail("Expected an incompatible protocol response")
        } catch SubsonicHTTPError.protocolIncompatible(let version, let message) {
            XCTAssertEqual(version, "1.14.0")
            XCTAssertEqual(message, "upgrade client")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testQueryServerInfoRejectsSuccessfulResponseWithoutVersion() async {
        URLProtocolStub.handler = { request in
            let body = Data("""
                {"subsonic-response":{"status":"ok","type":"navidrome"}}
                """.utf8)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        let client = SubsonicHTTPClient(session: makeSession())

        do {
            _ = try await client.queryServerInfo(
                baseUrl: "https://music.example",
                credentials: credentials
            )
            XCTFail("Expected a missing protocol version error")
        } catch SubsonicHTTPError.parseError(let message) {
            XCTAssertEqual(message, "Missing protocol version")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPingRetriesWithServerProtocolVersionAfterCodeThirty() async {
        var requestedVersions: [String] = []
        URLProtocolStub.handler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let version = try XCTUnwrap(
                components.queryItems?.first(where: { $0.name == "v" })?.value
            )
            requestedVersions.append(version)
            let body: Data
            if version == "1.16.0" {
                body = Data("""
                    {"subsonic-response":{"status":"failed","version":"1.14.0","error":{"code":30,"message":"unsupported version"}}}
                    """.utf8)
            } else {
                body = Data("""
                    {"subsonic-response":{"status":"ok","version":"1.14.0","type":"airsonic"}}
                    """.utf8)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, body)
        }
        let client = SubsonicHTTPClient(session: makeSession())

        let result = await client.ping(
            baseUrl: "https://music.example",
            username: "alice",
            password: "enc:736563726574",
            authType: "password"
        )

        XCTAssertTrue(result.reachable)
        XCTAssertNil(result.error)
        XCTAssertEqual(requestedVersions, ["1.16.0", "1.14.0"])
    }

    func testQueryServerInfoReturnsDowngradedProtocolVersion() async throws {
        URLProtocolStub.handler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let version = try XCTUnwrap(
                components.queryItems?.first(where: { $0.name == "v" })?.value
            )
            let payload = version == "1.16.0"
                ? "{\"subsonic-response\":{\"status\":\"failed\",\"version\":\"1.14.0\",\"error\":{\"code\":30,\"message\":\"unsupported version\"}}}"
                : "{\"subsonic-response\":{\"status\":\"ok\",\"version\":\"1.14.0\",\"type\":\"airsonic\"}}"
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(payload.utf8))
        }
        let client = SubsonicHTTPClient(session: makeSession())

        let info = try await client.queryServerInfo(
            baseUrl: "https://music.example",
            credentials: credentials
        )

        XCTAssertEqual(info.protocolVersion, "1.14.0")
        XCTAssertEqual(info.serverType, "airsonic")
    }

    private var credentials: ServerCredentials {
        ServerCredentials(
            serverUrl: "https://music.example",
            username: "alice",
            password: "enc:736563726574",
            authType: "password",
            protocolVersion: "1.16.0",
            serverType: "navidrome",
            fallbackUrl: nil
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("URLProtocolStub handler was not configured")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
