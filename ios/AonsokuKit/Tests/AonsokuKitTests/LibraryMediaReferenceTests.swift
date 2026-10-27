import XCTest

@testable import AonsokuKit

final class LibraryMediaReferenceTests: XCTestCase {
    func testEveryQueueImportDiscardsLegacyAuthenticationButKeepsStreamOptions() throws {
        let dictionary: [String: Any] = [
            "id": "track &+1", "title": "Title", "artist": "Artist", "album": "Album",
            "duration": 180.0, "streamUrl": legacyURL,
        ]
        let decoded = try JSONDecoder().decode(
            QueueSong.self, from: JSONSerialization.data(withJSONObject: dictionary)
        )
        let imported = QueueSong(from: dictionary)
        let constructed = song(url: legacyURL)

        for entry in [decoded, imported, constructed] {
            let reference = try XCTUnwrap(LibraryMediaReference(
                streamURL: entry.streamUrl, fallbackSongID: entry.id
            ))
            XCTAssertEqual(reference.songID, "track &+1")
            XCTAssertTrue(entry.streamUrl.contains("%2B"))
            XCTAssertEqual(reference.options, ["format": "mp3", "maxBitRate": "320", "timeOffset": "12"])
            let encoded = try JSONEncoder().encode(entry)
            let json = String(decoding: encoded, as: UTF8.self)
            XCTAssertFalse(json.contains("old-secret"))
            XCTAssertFalse(json.contains("old.example"))
            XCTAssertFalse(json.contains("estimateContentLength"))
            XCTAssertEqual(try JSONDecoder().decode(QueueSong.self, from: encoded), entry)
        }
    }

    func testResolutionUsesCurrentServerWithoutChangingIdentity() throws {
        let entry = song(url: legacyURL)
        let current = ServerCredentials(
            serverUrl: "https://current.example/music", username: "current-user", password: "new-secret",
            authType: "token", protocolVersion: "1.16.0", serverType: "navidrome", fallbackUrl: nil
        )
        let resolver = NativeSourceResolver(
            cacheDirectories: [], credentialsProvider: { current },
            estimateContentLengthProvider: { false }
        )

        let resolved = try XCTUnwrap(resolver.resolveSource(for: entry))
        let components = try XCTUnwrap(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.host, "current.example")
        XCTAssertEqual(components.path, "/music/rest/stream")
        XCTAssertTrue(resolved.url.absoluteString.contains("%2B"))
        XCTAssertEqual(query["u"], "current-user")
        XCTAssertEqual(query["id"], "track &+1")
        XCTAssertEqual(query["maxBitRate"], "320")
        XCTAssertEqual(query["estimateContentLength"], "false")
        XCTAssertEqual(entry.streamUrl, LibraryMediaReference(
            songID: "track &+1", options: ["format": "mp3", "maxBitRate": "320", "timeOffset": "12"]
        ).urlString)
    }

    func testQueueSnapshotPublishesIdentityInsteadOfResolvedTransport() throws {
        let entry = song(url: legacyURL)
        let snapshot = makePlayerSnapshot(context: [entry], currentIndex: 0, userQueue: [entry])
        let encoded = AudioPayloadCodec.encodeQueueSnapshot(snapshot)
        let context = try XCTUnwrap(encoded["contextQueue"] as? [String: Any])
        let contextSongs = try XCTUnwrap(context["songs"] as? [[String: Any]])
        let userSongs = try XCTUnwrap(encoded["userQueue"] as? [[String: Any]])

        XCTAssertEqual(contextSongs.first?["streamUrl"] as? String, entry.streamUrl)
        XCTAssertEqual(userSongs.first?["streamUrl"] as? String, entry.streamUrl)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: encoded), as: UTF8.self)
        XCTAssertFalse(json.contains("old-secret"))
        XCTAssertFalse(json.contains("old.example"))
    }

    func testOldPersistedQueuesMigrateEveryTierAndPreserveProgress() throws {
        let engine = NativeQueueEngine()
        engine.setContextQueue(songs: [song(url: legacyURL)], currentIndex: 0, autoplay: false,
                               startTime: nil, sourceId: nil, sourceName: nil)
        let state = PlaybackPersistState(from: engine, currentTime: 42)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let legacySong: [String: Any] = [
            "id": "track &+1", "title": "Title", "artist": "Artist", "album": "Album",
            "duration": 180.0, "streamUrl": legacyURL,
        ]
        let tiers = ["contextSongs", "userQueue", "originalContextSongs", "originalUserSongs", "playedUserQueueHistory"]
        for tier in tiers { object[tier] = [legacySong] }
        let restored = try JSONDecoder().decode(
            PlaybackPersistState.self, from: JSONSerialization.data(withJSONObject: object)
        )
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        for tier in tiers {
            let songs = try XCTUnwrap(rewritten[tier] as? [[String: Any]])
            XCTAssertEqual(songs.first?["streamUrl"] as? String, song(url: legacyURL).streamUrl)
        }
        XCTAssertEqual(restored.currentTime, 42)
        XCTAssertEqual(restored.currentIndex, 0)
    }

    func testExternalURLsIncludingUnauthenticatedStreamEndpointsRemainUnchanged() {
        let resolver = NativeSourceResolver(cacheDirectories: [], credentialsProvider: { nil })
        for url in [
            "https://radio.example/live?token=external-token",
            "http://127.0.0.1:1234/external-audio",
            "https://radio.example/rest/stream?id=radio",
            "file:///tmp/local.flac",
        ] {
            XCTAssertEqual(song(url: url).streamUrl, url)
            if url.hasPrefix("http") {
                XCTAssertEqual(resolver.resolveSource(for: song(url: url))?.url.absoluteString, url)
            }
        }
        XCTAssertNil(LibraryMediaReference(streamURL: "aonsoku-media://streaming?id=wrong", fallbackSongID: "fallback"))
    }

    func testLocalCacheResolutionKeepsTheLibraryReferenceForLaterFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = directory.appendingPathComponent("local.flac")
        try Data("audio".utf8).write(to: cached)
        let entry = QueueSong(id: "track &+1", title: "Title", artist: "Artist", album: "Album",
                              duration: 180, streamUrl: legacyURL, cachedFileUri: cached.absoluteString)
        let resolver = NativeSourceResolver(cacheDirectories: [], credentialsProvider: { nil })

        XCTAssertEqual(resolver.resolveSource(for: entry)?.url, cached)
        XCTAssertEqual(entry.toDict()["streamUrl"] as? String, song(url: legacyURL).streamUrl)
        resolver.rejectCachedFile(at: cached)
        XCTAssertNil(resolver.resolveSource(for: entry))
        XCTAssertEqual(entry.streamUrl, song(url: legacyURL).streamUrl)
    }

    private var legacyURL: String {
        "https://old.example/base/rest/stream.view?id=track%20%26%2B1&u=old-user&t=old-secret&s=old-salt&estimateContentLength=true&maxBitRate=320&format=mp3&timeOffset=12"
    }

    private func song(url: String) -> QueueSong {
        QueueSong(id: "track &+1", title: "Title", artist: "Artist", album: "Album", duration: 180, streamUrl: url)
    }
}
