import XCTest
@testable import AonsokuKit

final class SubsonicTransportTests: XCTestCase {
  override func tearDown() {
    URLProtocolStub.handler = nil
    super.tearDown()
  }

  // MARK: - URL Building

  func testSendBuildsUrlWithPathAndQuery() async throws {
    var capturedURL: URL?
    URLProtocolStub.handler = { request in
      capturedURL = request.url
      let body = Data("""
        {"subsonic-response": {"status": "ok"}}
        """.utf8)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in
        URL(string: "https://music.example/rest/test.view?u=alice&p=enc:secret")
      },
      session: makeSession()
    )

    let request = SubsonicRequest(
      "test.view",
      query: [URLQueryItem(name: "id", value: "123")]
    )
    _ = try await transport.send(request)

    let url = try XCTUnwrap(capturedURL)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = components.queryItems ?? []
    XCTAssertTrue(items.contains { $0.name == "u" && $0.value == "alice" })
    XCTAssertTrue(items.contains { $0.name == "id" && $0.value == "123" })
  }

  // MARK: - Percent Encoding

  func testSendPercentEncodesPlus() async throws {
    var capturedURL: URL?
    URLProtocolStub.handler = { request in
      capturedURL = request.url
      let body = Data("""
        {"subsonic-response": {"status": "ok"}}
        """.utf8)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let request = SubsonicRequest(
      "test.view",
      query: [URLQueryItem(name: "query", value: "song+name")]
    )
    _ = try await transport.send(request)

    guard let url = capturedURL else {
      XCTFail("No URL captured")
      return
    }
    let urlString = url.absoluteString
    XCTAssertTrue(urlString.contains("song%2Bname"))
  }

  func testSendPercentEncodesSpecialCharacters() async throws {
    var capturedURL: URL?
    URLProtocolStub.handler = { request in
      capturedURL = request.url
      let body = Data("""
        {"subsonic-response": {"status": "ok"}}
        """.utf8)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let request = SubsonicRequest(
      "test.view",
      query: [URLQueryItem(name: "query", value: "a&b=c")]
    )
    _ = try await transport.send(request)

    guard let url = capturedURL else {
      XCTFail("No URL captured")
      return
    }
    let urlString = url.absoluteString
    XCTAssertTrue(urlString.contains("a%26b%3Dc"))
  }

  // MARK: - HTTP Method

  func testSendUsesGetMethod() async throws {
    var capturedMethod: String?
    URLProtocolStub.handler = { request in
      capturedMethod = request.httpMethod
      let body = Data("""
        {"subsonic-response": {"status": "ok"}}
        """.utf8)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let request = SubsonicRequest("test.view", method: .get)
    _ = try await transport.send(request)

    XCTAssertEqual(capturedMethod, "GET")
  }

  func testSendUsesPostMethod() async throws {
    var capturedMethod: String?
    URLProtocolStub.handler = { request in
      capturedMethod = request.httpMethod
      let body = Data("""
        {"subsonic-response": {"status": "ok"}}
        """.utf8)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let request = SubsonicRequest("test.view", method: .post)
    _ = try await transport.send(request)

    XCTAssertEqual(capturedMethod, "POST")
  }

  // MARK: - Status Code Handling

  func testSend200SuccessReturnsData() async throws {
    let expectedData = Data("test data".utf8)
    URLProtocolStub.handler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, expectedData)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let data = try await transport.send(SubsonicRequest("test.view"))

    XCTAssertEqual(data, expectedData)
  }

  func testSend204NoContentReturnsData() async throws {
    let expectedData = Data()
    URLProtocolStub.handler = { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 204,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, expectedData)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let data = try await transport.send(SubsonicRequest("test.view"))

    XCTAssertEqual(data, expectedData)
  }

  func testSend404ThrowsUnsupported() async throws {
    URLProtocolStub.handler = { request in
      let body = Data()
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 404,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    do {
      _ = try await transport.send(SubsonicRequest("test.view"))
      XCTFail("Expected unsupported error")
    } catch SubsonicAPIError.unsupported {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSend501ThrowsUnsupported() async throws {
    URLProtocolStub.handler = { request in
      let body = Data()
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 501,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    do {
      _ = try await transport.send(SubsonicRequest("test.view"))
      XCTFail("Expected unsupported error")
    } catch SubsonicAPIError.unsupported {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testSend500ThrowsHttp() async throws {
    URLProtocolStub.handler = { request in
      let body = Data()
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 500,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    do {
      _ = try await transport.send(SubsonicRequest("test.view"))
      XCTFail("Expected http error")
    } catch SubsonicAPIError.http(let status) {
      XCTAssertEqual(status, 500)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - URL Building Failures

  func testSendWithoutCredentialsThrowsNotSignedIn() async throws {
    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in nil },
      session: makeSession()
    )

    do {
      _ = try await transport.send(SubsonicRequest("test.view"))
      XCTFail("Expected notSignedIn error")
    } catch SubsonicAPIError.notSignedIn {
      // Expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  // MARK: - Repeated Query Items

  func testSendPreservesRepeatedQueryItems() async throws {
    var capturedURL: URL?
    URLProtocolStub.handler = { request in
      capturedURL = request.url
      let body = Data("""
        {"subsonic-response": {"status": "ok"}}
        """.utf8)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, body)
    }

    let transport = AuthenticatedSubsonicTransport(
      urlBuilder: { _ in URL(string: "https://music.example/rest/test.view") },
      session: makeSession()
    )

    let request = SubsonicRequest(
      "test.view",
      query: [
        URLQueryItem(name: "id", value: "s1"),
        URLQueryItem(name: "id", value: "s2"),
        URLQueryItem(name: "id", value: "s3")
      ]
    )
    _ = try await transport.send(request)

    let url = try XCTUnwrap(capturedURL)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let idItems = (components.queryItems ?? []).filter { $0.name == "id" }
    XCTAssertEqual(idItems.count, 3)
  }
}

private func makeSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [URLProtocolStub.self]
  return URLSession(configuration: configuration)
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
