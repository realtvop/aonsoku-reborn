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

    func testDownloadURLCarriesAuthenticationAndTranscodingOptions() throws {
        let manager = makeManager()
        let credentials = ServerCredentials(
            serverUrl: "https://music.example/",
            username: "alice",
            password: "token",
            authType: "token",
            protocolVersion: "1.16.0",
            serverType: "navidrome",
            fallbackUrl: nil
        )
        let url = try XCTUnwrap(manager.buildDownloadURL(
            songId: "song 1",
            credentials: credentials,
            maxBitRate: 320,
            format: "mp3"
        ))
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                item in item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.path, "/rest/stream")
        XCTAssertEqual(query["id"], "song 1")
        XCTAssertEqual(query["maxBitRate"], "320")
        XCTAssertEqual(query["format"], "mp3")
        XCTAssertEqual(query["estimateContentLength"], "true")
    }

    func testMissingCredentialsFailsBeforeCreatingNetworkSession() {
        var sessionCreations = 0
        let manager = NativeDownloadManager(
            sessionFactory: { delegate in
                sessionCreations += 1
                return URLSession(
                    configuration: .ephemeral,
                    delegate: delegate,
                    delegateQueue: nil
                )
            },
            credentialsProvider: { nil }
        )
        let delegate = DownloadDelegateSpy()
        manager.delegate = delegate

        manager.download(songId: "song-1")

        XCTAssertEqual(sessionCreations, 0)
        XCTAssertEqual(delegate.failedSongIds, ["song-1"])
    }

    func testBackgroundRelaunchCompletionIsOwnedOnlyForMatchingIdentifier() {
        var session: URLSession?
        let manager = NativeDownloadManager(sessionFactory: { delegate in
            let created = URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
            session = created
            return created
        })
        XCTAssertFalse(manager.handleEvents(
            forBackgroundSession: "other.session",
            completionHandler: {}
        ))

        let completed = expectation(description: "background completion")
        XCTAssertTrue(manager.handleEvents(
            forBackgroundSession: NativeDownloadManager.backgroundSessionIdentifier,
            completionHandler: { completed.fulfill() }
        ))
        manager.urlSessionDidFinishEvents(
            forBackgroundURLSession: try! XCTUnwrap(session)
        )

        wait(for: [completed], timeout: 1)
    }

    private func makeManager() -> NativeDownloadManager {
        NativeDownloadManager(sessionFactory: { delegate in
            URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
        })
    }
}

private final class DownloadDelegateSpy: NativeDownloadManagerDelegate {
    var failedSongIds: [String] = []

    func downloadManager(
        _ manager: NativeDownloadManager,
        didProgress songId: String,
        loaded: Int64,
        total: Int64
    ) {}

    func downloadManager(
        _ manager: NativeDownloadManager,
        didComplete songId: String,
        fileUrl: URL,
        contentType: String,
        sizeBytes: Int64
    ) {}

    func downloadManager(
        _ manager: NativeDownloadManager,
        didFail songId: String,
        error: Error
    ) {
        failedSongIds.append(songId)
    }
}
