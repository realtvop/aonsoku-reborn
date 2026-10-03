import XCTest
@testable import AonsokuNativePlugin

final class DownloadTests: XCTestCase {
    func testCacheIdentityIsPathSafeAndStable() {
        let id = AudioCacheUtils.cacheId(for: "folder/song+=")

        XCTAssertEqual(id, AudioCacheUtils.cacheId(for: "folder/song+="))
        XCTAssertFalse(id.contains("/"))
        XCTAssertFalse(id.contains("+"))
        XCTAssertFalse(id.contains("="))
    }

    func testContentTypeSelectsExpectedFileExtension() {
        XCTAssertEqual(AudioCacheUtils.fileExtension(for: "audio/flac; charset=binary"), "flac")
        XCTAssertEqual(AudioCacheUtils.fileExtension(for: "audio/mpeg"), "mp3")
        XCTAssertEqual(AudioCacheUtils.fileExtension(for: "application/octet-stream"), "audio")
    }

    func testBackgroundSessionIdentifierIsStable() {
        XCTAssertEqual(
            NativeDownloadManager.backgroundSessionIdentifier,
            "github.realtvop.aonsoku.audio.downloads"
        )
    }
}
