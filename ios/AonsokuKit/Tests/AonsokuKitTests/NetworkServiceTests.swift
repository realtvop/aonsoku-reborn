import XCTest

@testable import AonsokuKit

final class NetworkServiceTests: XCTestCase {
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
