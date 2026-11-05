import UIKit
import XCTest
@testable import AonsokuKit

final class OriginalCoverTests: XCTestCase {
    func testOriginalRequestOmitsSizeAndCannotBeDowngradedByThumbnail() async throws {
        let fixture = try TemporaryDatabase()
        let requests = LockedTestBox<[URL]>([])
        let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 24)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 24))
        }
        let client = HTTPClient { request in
            requests.update { $0.append(request.url!) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!)
        }
        let cache = ImageCacheManager(db: fixture.manager.dbPool, client: client,
            credentialsProvider: {
                ServerCredentials(serverUrl: "https://fixture.invalid", username: "fixture", password: "fixture",
                    authType: "token", protocolVersion: "1.16.0", serverType: "subsonic", fallbackUrl: nil)
            })
        let id = "original-\(UUID().uuidString)"
        defer { _ = try? cache.deleteCoverImage(coverArtId: id) }
        _ = try await cache.downloadCoverImage(coverArtId: id, size: "original")
        let url = try XCTUnwrap(requests.read { $0.first })
        XCTAssertFalse(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "size" })
        XCTAssertEqual(cache.readCoverImage(coverArtId: id)?.quality, "original")
        XCTAssertEqual(cache.readCoverImage(coverArtId: id)?.data, data)
        _ = try cache.storeCoverImage(coverArtId: id, data: Data([0]), contentType: "image/png", coverSize: "700")
        XCTAssertEqual(cache.readCoverImage(coverArtId: id)?.quality, "original")
        XCTAssertEqual(cache.readCoverImage(coverArtId: id)?.data, data)
    }
}
