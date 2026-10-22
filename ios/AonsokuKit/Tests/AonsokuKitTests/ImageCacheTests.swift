import XCTest
@testable import AonsokuKit

final class ImageCacheTests: XCTestCase {
    func testCacheIdentityIsURLSafeStableAndDistinct() {
        let first = ImageCacheUtils.cacheId(for: "cover/+=one")
        XCTAssertEqual(first, ImageCacheUtils.cacheId(for: "cover/+=one"))
        XCTAssertNotEqual(first, ImageCacheUtils.cacheId(for: "cover-two"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains("+"))
        XCTAssertFalse(first.contains("="))
    }

    func testImageMIMETypesChooseCompatibleExtensions() {
        XCTAssertEqual(ImageCacheUtils.fileExtension(for: "image/jpeg"), "jpg")
        XCTAssertEqual(ImageCacheUtils.fileExtension(for: "image/png"), "png")
        XCTAssertEqual(ImageCacheUtils.fileExtension(for: "image/webp"), "webp")
        XCTAssertEqual(ImageCacheUtils.fileExtension(for: "image/gif"), "gif")
        XCTAssertEqual(
            ImageCacheUtils.fileExtension(for: "image/jpeg; charset=utf-8"),
            "jpg"
        )
        XCTAssertEqual(
            ImageCacheUtils.fileExtension(for: "application/octet-stream"),
            "jpg"
        )
    }

    func testLookupAndDeletionUseOnlyKnownExtensions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aonsoku-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cacheId = ImageCacheUtils.cacheId(for: "cover-1")
        let webp = directory.appendingPathComponent("\(cacheId).webp")
        let unrelated = directory.appendingPathComponent("\(cacheId).txt")
        try Data("cover".utf8).write(to: webp)
        try Data("keep".utf8).write(to: unrelated)

        XCTAssertEqual(
            ImageCacheUtils.coverImageURL(in: directory, cacheId: cacheId),
            webp
        )
        XCTAssertTrue(
            ImageCacheUtils.removeCoverImageFiles(in: directory, cacheId: cacheId)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: webp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testFailedCoverUpgradePreservesExistingFileAndMetadata() async throws {
        let database = try TemporaryDatabase()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageCacheURLProtocolStub.self]
        ImageCacheURLProtocolStub.error = URLError(.notConnectedToInternet)
        let manager = ImageCacheManager(
            db: database.manager.dbPool,
            session: URLSession(configuration: configuration),
            credentialsProvider: {
                ServerCredentials(
                    serverUrl: "https://music.test",
                    username: "user",
                    password: "password",
                    authType: "password",
                    protocolVersion: "1.16.1",
                    serverType: "navidrome",
                    fallbackUrl: nil
                )
            }
        )
        let coverArtId = "failed-upgrade-\(UUID().uuidString)"
        let originalData = Data("original-cover".utf8)
        let originalURL = try manager.storeCoverImage(
            coverArtId: coverArtId,
            data: originalData,
            contentType: "image/png",
            coverSize: "300"
        )
        defer { _ = try? manager.deleteCoverImage(coverArtId: coverArtId) }

        do {
            _ = try await manager.downloadCoverImage(
                coverArtId: coverArtId,
                size: "900"
            )
            XCTFail("Expected the upgrade download to fail")
        } catch {}

        XCTAssertEqual(manager.resolveCoverImage(coverArtId: coverArtId), originalURL)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        let metadata = try CacheMetaRepository(
            db: database.manager.dbPool
        ).getByKey("cover:\(coverArtId)")
        XCTAssertEqual(metadata?.coverSize, "300")
        XCTAssertEqual(metadata?.sizeBytes, originalData.count)
    }
}

private final class ImageCacheURLProtocolStub: URLProtocol {
    static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: Self.error ?? URLError(.unknown)
        )
    }

    override func stopLoading() {}
}
