import XCTest
@testable import AonsokuNativePlugin

final class HTTPClientTests: XCTestCase {
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
