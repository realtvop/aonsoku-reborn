import XCTest
@testable import AonsokuKit

@MainActor
final class StreamRequestSettingsTests: XCTestCase {
    func testOldSettingsDefaultToEnabledAndExplicitDisableSurvivesReload() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        preferences.setString(
            #"{"playback":{"hapticFeedback":false}}"#,
            for: SettingsStore.storageKey
        )
        let store = SettingsStore(preferences: preferences)
        store.load()
        XCTAssertFalse(store.settings.playback.hapticFeedback)
        XCTAssertTrue(store.settings.playback.estimateContentLength)
        XCTAssertTrue(preferences.estimateStreamContentLength)

        store.update { $0.playback.estimateContentLength = false }
        let restored = SettingsStore(preferences: preferences)
        restored.load()
        XCTAssertFalse(restored.settings.playback.estimateContentLength)
        XCTAssertFalse(preferences.estimateStreamContentLength)

        restored.reset()
        XCTAssertTrue(preferences.estimateStreamContentLength)
    }

    func testNewStreamsRestoredQueueURLsAndDownloadsReadTheLatestSetting() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let store = SettingsStore(preferences: preferences)
        let credentials = ServerCredentials(
            serverUrl: "https://music.example/base/",
            username: "alice",
            password: "token-value",
            authType: "token",
            protocolVersion: "1.16.0",
            serverType: "navidrome",
            fallbackUrl: nil
        )
        let estimate = { preferences.estimateStreamContentLength }
        let authentication = AuthenticationService(
            credentialsProvider: { credentials },
            estimateContentLengthProvider: estimate
        )
        let resolver = NativeSourceResolver(
            cacheDirectories: [],
            credentialsProvider: { credentials },
            estimateContentLengthProvider: estimate
        )
        let manager = NativeDownloadManager(
            sessionFactory: { _ in
                XCTFail("Building a download URL must not create a network session")
                return URLSession(configuration: .ephemeral)
            },
            estimateContentLengthProvider: estimate
        )
        let songId = "song &1"
        let queuedURL = try XCTUnwrap(authentication.streamURL(songId: songId))
        XCTAssertEqual(query(queuedURL)["estimateContentLength"], "true")

        // Keep the original queued URL while settings change, as a paused or
        // restored queue does. Both endpoint spellings must pick up the change.
        var queued = try XCTUnwrap(URLComponents(url: queuedURL, resolvingAgainstBaseURL: false))
        queued.queryItems?.append(URLQueryItem(name: "maxBitRate", value: "320"))
        queued.queryItems?.append(URLQueryItem(name: "format", value: "mp3"))
        for enabled in [false, true] {
            store.update { $0.playback.estimateContentLength = enabled }
            let expected = String(enabled)
            let freshURL = try XCTUnwrap(authentication.streamURL(songId: songId))
            XCTAssertEqual(query(freshURL)["estimateContentLength"], expected)
            XCTAssertEqual(freshURL.path, "/base/rest/stream.view")

            for path in ["/base/rest/stream", "/base/rest/stream.view"] {
                queued.path = path
                let result = try XCTUnwrap(resolver.resolveSource(for: song(
                    id: songId, url: try XCTUnwrap(queued.url).absoluteString
                )))
                let values = query(result.url)
                XCTAssertEqual(values["estimateContentLength"], expected)
                XCTAssertEqual(values["id"], songId)
                XCTAssertEqual(values["maxBitRate"], "320")
                XCTAssertEqual(values["format"], "mp3")
                XCTAssertEqual(values["u"], "alice")
                XCTAssertEqual(result.url.path, path)
            }

            var customURL = URLComponents()
            customURL.scheme = "aonsoku-media"
            customURL.host = "stream"
            customURL.queryItems = [URLQueryItem(name: "id", value: songId)]
            let resolved = try XCTUnwrap(resolver.resolveSource(for: song(
                id: songId, url: try XCTUnwrap(customURL.string)
            )))
            XCTAssertEqual(query(resolved.url)["estimateContentLength"], expected)
            let downloadURL = try XCTUnwrap(manager.buildDownloadURL(
                songId: songId, credentials: credentials, maxBitRate: nil, format: nil
            ))
            XCTAssertEqual(query(downloadURL)["estimateContentLength"], expected)
        }
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        ).compactMap { item in item.value.map { (item.name, $0) } })
    }

    private func song(id: String, url: String) -> QueueSong {
        QueueSong(id: id, title: "Song", artist: "Artist", album: "Album", duration: 0, streamUrl: url)
    }
}
