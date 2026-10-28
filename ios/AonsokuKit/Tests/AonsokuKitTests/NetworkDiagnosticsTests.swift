import XCTest
@testable import AonsokuKit

final class NetworkDiagnosticsTests: XCTestCase {
    func testTargetsAndNestedErrorsExcludeCredentialsAndDescriptions() throws {
        let url = try XCTUnwrap(URL(string: "http://alice:secret@192.168.50.123:4533/music/rest/stream?p=secret&t=token-secret"))
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1000,
                                 userInfo: [NSLocalizedDescriptionKey: url.absoluteString])
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: url.absoluteString,
            NSUnderlyingErrorKey: underlying
        ])
        let message = NetworkDiagnostics.target(url) + " " + NetworkDiagnostics.failure(failure, taskCancelled: false)
        XCTAssertTrue(message.contains("host=192.168.50.123 port=4533 endpoint=stream"))
        XCTAssertTrue(message.contains("reason=badURL"))
        XCTAssertTrue(message.contains("underlying=kCFErrorDomainCFNetwork:-1000"))
        XCTAssertFalse(message.contains("alice"))
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("?"))
        XCTAssertFalse(message.contains("/music"))
    }

    func testLoaderEncodingAndExternalPathsAreNotLogged() throws {
        let original = try XCTUnwrap(URL(string: "https://music.test/rest/stream?p=secret"))
        let loaderURL = try XCTUnwrap(StreamingResourceLoader.loaderURL(for: original))
        let loader = NetworkDiagnostics.target(loaderURL)
        XCTAssertTrue(loader.contains("scheme=aonsoku-loader"))
        XCTAssertTrue(loader.contains("endpoint=other"))
        XCTAssertFalse(loader.contains(loaderURL.lastPathComponent))
        let external = NetworkDiagnostics.target(URL(string: "https://radio.test/private-token-secret"))
        XCTAssertFalse(external.contains("private-token-secret"))
    }

    func testCancellationDistinguishesTransportFromCallerAndReadiness() {
        XCTAssertTrue(NetworkDiagnostics.failure(URLError(.cancelled), taskCancelled: false)
            .contains("reason=urlSessionCancelled domain=NSURLErrorDomain code=-999 taskCancelled=false"))
        XCTAssertTrue(NetworkDiagnostics.failure(CancellationError(), taskCancelled: true)
            .contains("reason=taskCancelled"))
        XCTAssertTrue(NetworkDiagnostics.failure(SubsonicAPIError.cancelled).contains("reason=apiCancelled"))
        XCTAssertTrue(NetworkDiagnostics.failure(TailscaleReadinessError.missingSubnetRoute("192.168.50.123"))
            .contains("reason=missingSubnetRoute"))
    }
}
