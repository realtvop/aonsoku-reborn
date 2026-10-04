import XCTest
@testable import AonsokuNativePlugin

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
}
