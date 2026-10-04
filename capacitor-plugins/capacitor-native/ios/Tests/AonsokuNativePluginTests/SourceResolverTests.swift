import XCTest
@testable import AonsokuNativePlugin

final class SourceResolverTests: XCTestCase {
    func testExplicitAndDiscoveredCachedFilesWinBeforeNetworkSource() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let explicit = directory.appendingPathComponent("explicit.flac")
        try Data("audio".utf8).write(to: explicit)
        let resolver = NativeSourceResolver(
            cacheDirectories: [directory],
            credentialsProvider: { nil }
        )

        let explicitResult = resolver.resolveSource(for: makeSong(
            "one",
            streamURL: "aonsoku-media://stream?id=one",
            cachedFileURI: explicit.path
        ))
        XCTAssertEqual(explicitResult?.kind, "native-file")
        XCTAssertEqual(explicitResult?.url, explicit)

        let cacheID = AudioCacheUtils.cacheId(for: "two")
        let discovered = directory.appendingPathComponent("\(cacheID).mp3")
        try Data("audio".utf8).write(to: discovered)
        let discoveredResult = resolver.resolveSource(for: makeSong(
            "two",
            streamURL: "aonsoku-media://stream?id=two"
        ))
        XCTAssertEqual(discoveredResult?.url, discovered)
    }

    func testDirectHTTPAndRadioURLsPassThroughWithoutCredentials() {
        let resolver = NativeSourceResolver(
            cacheDirectories: [],
            credentialsProvider: { nil }
        )

        for url in [
            "http://radio.example.test/stream.mp3",
            "https://radio.example.test/live",
        ] {
            let result = resolver.resolveSource(for: makeSong("radio", streamURL: url))
            XCTAssertEqual(result?.kind, "stream")
            XCTAssertEqual(result?.url.absoluteString, url)
        }
    }

    func testCustomStreamRequiresCredentialsAndBuildsAuthenticatedURL() throws {
        let resolver = NativeSourceResolver(
            cacheDirectories: [],
            credentialsProvider: { self.credentials }
        )

        let result = try XCTUnwrap(resolver.resolveSource(for: makeSong(
            "fallback",
            streamURL: "aonsoku-media://stream?id=song-1"
        )))
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )
        let query = queryDictionary(components)

        XCTAssertEqual(components.path, "/rest/stream")
        XCTAssertEqual(query["u"], "alice")
        XCTAssertEqual(query["id"], "song-1")
        XCTAssertEqual(query["estimateContentLength"], "true")
        XCTAssertNil(
            NativeSourceResolver(
                cacheDirectories: [],
                credentialsProvider: { nil }
            ).resolveSource(for: makeSong(
                "song-1",
                streamURL: "aonsoku-media://stream?id=song-1"
            ))
        )
    }

    func testCustomStreamPreservesTranscodingOptions() throws {
        let resolver = NativeSourceResolver(
            cacheDirectories: [],
            credentialsProvider: { self.credentials }
        )
        let result = try XCTUnwrap(resolver.resolveSource(for: makeSong(
            "song-1",
            streamURL: "aonsoku-media://stream?id=song-1&maxBitRate=320&format=mp3"
        )))
        let components = try XCTUnwrap(
            URLComponents(url: result.url, resolvingAgainstBaseURL: false)
        )
        let query = queryDictionary(components)

        XCTAssertEqual(query["maxBitRate"], "320")
        XCTAssertEqual(query["format"], "mp3")
    }

    func testCredentialCacheCanBeInvalidatedDeterministically() throws {
        var username = "first"
        let resolver = NativeSourceResolver(
            cacheDirectories: [],
            credentialsProvider: {
                var value = self.credentials
                value = ServerCredentials(
                    serverUrl: value.serverUrl,
                    username: username,
                    password: value.password,
                    authType: value.authType,
                    protocolVersion: value.protocolVersion,
                    serverType: value.serverType,
                    fallbackUrl: value.fallbackUrl
                )
                return value
            }
        )
        let first = try XCTUnwrap(resolver.buildStreamUrl(songId: "song"))
        username = "second"
        let cached = try XCTUnwrap(resolver.buildStreamUrl(songId: "song"))
        resolver.invalidateCredentialsCache()
        let refreshed = try XCTUnwrap(resolver.buildStreamUrl(songId: "song"))

        XCTAssertTrue(first.contains("u=first"))
        XCTAssertEqual(first, cached)
        XCTAssertTrue(refreshed.contains("u=second"))
    }

    private var credentials: ServerCredentials {
        ServerCredentials(
            serverUrl: "https://music.example/",
            username: "alice",
            password: "token-value",
            authType: "token",
            protocolVersion: "1.16.0",
            serverType: "navidrome",
            fallbackUrl: nil
        )
    }

    private func makeSong(
        _ id: String,
        streamURL: String,
        cachedFileURI: String? = nil
    ) -> QueueSong {
        QueueSong(
            id: id,
            title: id,
            artist: "Artist",
            album: "Album",
            duration: 180,
            streamUrl: streamURL,
            cachedFileUri: cachedFileURI
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aonsoku-source-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func queryDictionary(_ components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item in item.value.map { (item.name, $0) }
        })
    }
}
