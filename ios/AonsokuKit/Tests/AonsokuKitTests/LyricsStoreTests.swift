import XCTest

@testable import AonsokuKit

@MainActor
final class LyricsStoreTests: XCTestCase {
    override func tearDown() {
        LyricsURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSourceOrderSkipsDisabledSources() async throws {
        let fixture = try LyricsStoreFixture()
        fixture.settings.update {
            $0.lyrics.sourcePriority = [.lrclib, .custom, .navidrome]
            $0.lyrics.customServerEnabled = false
            $0.privacy.lrcLibEnabled = false
        }
        let calls = LockedTestBox<[String]>([])
        fixture.api.lyricsBySongIdHandler = { id in
            calls.update { $0.append("structured:\(id)") }
            return []
        }
        fixture.api.lyricsHandler = { artist, title in
            calls.update { $0.append("plain:\(artist):\(title)") }
            return SubsonicPlainLyrics(value: "Server line")
        }
        LyricsURLProtocolStub.handler = { _ in
            XCTFail("Disabled network sources must not be requested")
            throw URLError(.unsupportedURL)
        }

        await fixture.store.load(for: mediaSong("one"))

        let lyrics = try loaded(fixture.store)
        XCTAssertEqual(lyrics.source, .navidrome)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Server line"])
        XCTAssertEqual(calls.read { $0 }, ["structured:one", "plain:Artist:Title one"])
    }

    func testPreferSyncedKeepsLookingPastPlainResult() async throws {
        let writes = LockedTestBox<[(String, Bool)]>([])
        let fixture = try LyricsStoreFixture(storeCachedLyrics: { id, _, synced in
            writes.update { $0.append((id, synced)) }
        })
        fixture.settings.update {
            $0.lyrics.preferSyncedLyrics = true
            $0.lyrics.sourcePriority = [.navidrome, .lrclib, .custom]
            $0.lyrics.customServerEnabled = false
        }
        fixture.api.lyricsBySongIdHandler = { _ in
            [
                SubsonicStructuredLyrics(
                    synced: false,
                    lines: [.init(value: "Structured plain")]
                )
            ]
        }
        fixture.api.lyricsHandler = { _, _ in SubsonicPlainLyrics(value: "Plain") }
        fixture.store.urlSession = makeLyricsSession()
        LyricsURLProtocolStub.handler = { request in
            let body = Data(#"{"plainLyrics":"Plain LRC","syncedLyrics":"[00:01.00]Synced"}"#.utf8)
            return (lyricsResponse(request, contentType: "application/json"), body)
        }

        await fixture.store.load(for: mediaSong("sync"))

        let lyrics = try loaded(fixture.store)
        XCTAssertEqual(lyrics.source, .lrclib)
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.first?.text, "Synced")
        XCTAssertEqual(writes.read { $0.map(\.0) }, ["sync"])
        XCTAssertEqual(writes.read { $0.map(\.1) }, [true])
    }

    func testCustomSearchProtocolAndCandidateKeys() async throws {
        let fixture = try LyricsStoreFixture()
        fixture.settings.update {
            $0.lyrics.customServerEnabled = true
            $0.lyrics.customServerUrl = "https://lyrics.example/search?existing=1"
            $0.lyrics.customServerPassword = "secret"
        }
        fixture.store.urlSession = makeLyricsSession()
        let captured = LockedTestBox<URLRequest?>(nil)
        LyricsURLProtocolStub.handler = { request in
            captured.update { $0 = request }
            let body = Data(
                """
                [
                  {"id":"server-1","title":"First","artist":"A","lyrics":"[00:01.00]One"},
                  {"title":"Second","artist":"B","lyrics":"Two","romaji":"romaji"},
                  {"title":"Empty","lyrics":"  "}
                ]
                """.utf8)
            return (lyricsResponse(request, contentType: "application/json; charset=utf-8"), body)
        }

        let candidates = try await fixture.store.searchCandidates(
            title: " Song ", artist: " Artist ")

        XCTAssertEqual(candidates.map(\.id), ["server-1", "1:B:Second"])
        XCTAssertEqual(candidates.map(\.isSynced), [true, false])
        let request = try XCTUnwrap(captured.read { $0 })
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
        XCTAssertEqual(query["existing"], "1")
        XCTAssertEqual(query["title"], "Song")
        XCTAssertEqual(query["artist"], "Artist")
        XCTAssertNil(query["offset"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "secret")
    }

    func testLRCLibRequestUsesLMSArtistAndClientHeader() async throws {
        let fixture = try LyricsStoreFixture()
        fixture.settings.update {
            $0.lyrics.sourcePriority = [.lrclib, .navidrome, .custom]
            $0.lyrics.customServerEnabled = false
        }
        fixture.store.serverType = { "lms" }
        fixture.store.urlSession = makeLyricsSession()
        let captured = LockedTestBox<URLRequest?>(nil)
        LyricsURLProtocolStub.handler = { request in
            captured.update { $0 = request }
            let body = Data(#"{"plainLyrics":"Words","syncedLyrics":null}"#.utf8)
            return (lyricsResponse(request, contentType: "application/json"), body)
        }

        var song = mediaSong("lrc")
        song.artist = "First, Second"
        song.album = "Album Name"
        await fixture.store.load(for: song)

        let request = try XCTUnwrap(captured.read { $0 })
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
        XCTAssertEqual(query["artist_name"], "First")
        XCTAssertEqual(query["track_name"], song.title)
        XCTAssertEqual(query["album_name"], "Album Name")
        XCTAssertEqual(query["duration"], "180")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Lrclib-Client"),
            "Aonsoku v1.2.3 (https://github.com/realtvop/aonsoku-reborn)"
        )
    }

    func testSelectedCustomLyricsWinOverEveryAutomaticSource() async throws {
        let fixture = try LyricsStoreFixture()
        fixture.settings.update {
            $0.privacy.lrcLibEnabled = false
            $0.lyrics.customServerEnabled = false
        }
        let navidromeCalls = LockedTestBox(0)
        fixture.api.lyricsBySongIdHandler = { _ in
            navidromeCalls.update { $0 += 1 }
            return [
                SubsonicStructuredLyrics(
                    synced: true,
                    lines: [.init(start: 0, value: "Automatic")]
                )
            ]
        }
        let song = mediaSong("selected")
        await fixture.store.load(for: song)
        XCTAssertEqual(try loaded(fixture.store).lines.first?.text, "Automatic")

        await fixture.store.select(
            CustomLyricsCandidate(
                id: "picked",
                title: song.title,
                artist: song.artist,
                isSynced: true,
                lyrics: "[00:02.00]Selected",
                romaji: "[00:02.00]selected-romaji"
            ))

        let lyrics = try loaded(fixture.store)
        XCTAssertEqual(lyrics.source, .custom)
        XCTAssertEqual(lyrics.lines.first?.text, "Selected")
        XCTAssertEqual(lyrics.lines.first?.romanization, "selected-romaji")
        XCTAssertEqual(navidromeCalls.read { $0 }, 1)
    }

    func testOfflineFailureUsesLibraryCache() async throws {
        let cached = LibraryLyrics(
            songId: "offline",
            content: "[00:01.00]Cached",
            synced: true,
            cachedAt: 1,
            lastAccessedAt: 1
        )
        let fixture = try LyricsStoreFixture(cachedLyrics: { id in
            id == "offline" ? cached : nil
        })
        fixture.settings.update {
            $0.privacy.lrcLibEnabled = false
            $0.lyrics.customServerEnabled = false
        }
        fixture.api.lyricsBySongIdHandler = { _ in throw SubsonicAPIError.offline }
        fixture.api.lyricsHandler = { _, _ in throw SubsonicAPIError.timedOut }

        await fixture.store.load(for: mediaSong("offline"))

        let lyrics = try loaded(fixture.store)
        XCTAssertEqual(lyrics.lines.first?.text, "Cached")
        XCTAssertTrue(lyrics.isSynced)
    }

    func testConcurrentSameSongSharesLoadAndOlderSongCannotOverwrite() async throws {
        let fixture = try LyricsStoreFixture()
        fixture.settings.update {
            $0.privacy.lrcLibEnabled = false
            $0.lyrics.customServerEnabled = false
        }
        let firstGate = LyricsAsyncGate()
        let calls = LockedTestBox<[String: Int]>([:])
        fixture.api.lyricsBySongIdHandler = { id in
            calls.update { $0[id, default: 0] += 1 }
            if id == "old" { await firstGate.wait() }
            return [
                SubsonicStructuredLyrics(
                    synced: true,
                    lines: [.init(start: 0, value: id)]
                )
            ]
        }

        let first = Task { await fixture.store.load(for: self.mediaSong("old")) }
        await waitUntil { calls.read { $0["old"] == 1 } }
        let shared = Task { await fixture.store.load(for: self.mediaSong("old")) }
        await Task.yield()
        XCTAssertEqual(calls.read { $0["old"] }, 1)

        await fixture.store.load(for: mediaSong("new"))
        await firstGate.open()
        await first.value
        await shared.value

        XCTAssertEqual(fixture.store.songId, "new")
        XCTAssertEqual(try loaded(fixture.store).lines.first?.text, "new")
    }

    func testSelectionPersistenceOffsetDisableResetAndDefaultRemoval() async throws {
        let fixture = try LyricsStoreFixture()
        fixture.settings.update {
            $0.privacy.lrcLibEnabled = false
            $0.lyrics.customServerEnabled = false
        }
        fixture.api.lyricsBySongIdHandler = { _ in [] }
        fixture.api.lyricsHandler = { _, _ in SubsonicPlainLyrics(value: "Automatic") }
        let song = mediaSong("choice")
        await fixture.store.load(for: song)

        fixture.store.setOffset(0.26)
        XCTAssertEqual(fixture.store.selection.offset, 0.3, accuracy: 0.000_001)
        await fixture.store.select(
            CustomLyricsCandidate(
                id: "custom",
                title: "Chosen",
                artist: "Writer",
                isSynced: false,
                lyrics: "Chosen words"
            ))
        XCTAssertEqual(fixture.store.selection.key, "custom")
        XCTAssertEqual(fixture.store.selection.offset, 0.3, accuracy: 0.000_001)

        await fixture.store.resetSelection()
        XCTAssertNil(fixture.store.selection.key)
        XCTAssertEqual(fixture.store.selection.offset, 0.3, accuracy: 0.000_001)
        fixture.store.setOffset(99)
        XCTAssertEqual(fixture.store.selection.offset, 2)
        await fixture.store.setDisabled(true)
        XCTAssertEqual(fixture.store.state, .disabled)
        await fixture.store.setDisabled(false)
        XCTAssertNotEqual(fixture.store.state, .disabled)
        fixture.store.setOffset(0)

        XCTAssertNil(fixture.preferences.getString("lyrics.selections.v1"))
    }

    func testSelectionsKeepOnlyFiftyMostRecentlyChangedSongs() async throws {
        let clock = LockedTestBox(0)
        let fixture = try LyricsStoreFixture(now: {
            clock.update { $0 += 1 }
            return Date(timeIntervalSince1970: TimeInterval(clock.read { $0 }))
        })
        fixture.settings.update {
            $0.privacy.lrcLibEnabled = false
            $0.lyrics.customServerEnabled = false
        }
        fixture.api.lyricsBySongIdHandler = { _ in [] }
        fixture.api.lyricsHandler = { _, _ in SubsonicPlainLyrics(value: "Words") }

        for index in 0..<52 {
            await fixture.store.load(for: mediaSong("limit-\(index)"))
            fixture.store.setOffset(0.1)
        }

        let data = try XCTUnwrap(
            fixture.preferences.getString("lyrics.selections.v1")?.data(using: .utf8)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object.count, 50)
        XCTAssertFalse(object.keys.contains("/limit-0\u{1F}Artist\u{1F}Title limit-0\u{1F}Album"))
        XCTAssertFalse(object.keys.contains("/limit-1\u{1F}Artist\u{1F}Title limit-1\u{1F}Album"))
        XCTAssertTrue(object.keys.contains("/limit-51\u{1F}Artist\u{1F}Title limit-51\u{1F}Album"))
    }

    private func mediaSong(_ id: String) -> Song {
        Song(
            id: id,
            title: "Title \(id)",
            album: "Album",
            artist: "Artist",
            duration: 180,
            path: "/\(id)"
        )
    }

    private func loaded(_ store: LyricsStore) throws -> SongLyrics {
        guard case .loaded(let lyrics) = store.state else {
            XCTFail("Expected loaded lyrics, got \(store.state)")
            throw LyricsTestError.notLoaded
        }
        return lyrics
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class LyricsStoreFixture {
    let database: TemporaryDatabase
    let api: FakeSubsonicAPI
    let library: LibraryService
    let preferences: PreferencesService
    let settings: SettingsStore
    let store: LyricsStore

    init(
        cachedLyrics: @escaping (String) throws -> LibraryLyrics? = { _ in nil },
        storeCachedLyrics: @escaping (String, String, Bool) throws -> Void = { _, _, _ in },
        now: @escaping () -> Date = Date.init
    ) throws {
        database = try TemporaryDatabase()
        api = FakeSubsonicAPI()
        library = LibraryService(
            dbManager: database.manager,
            credentialsProvider: { nil }
        )
        preferences = PreferencesService(db: database.manager.dbPool)
        settings = SettingsStore(preferences: preferences)
        store = LyricsStore(
            api: api,
            library: library,
            settings: settings,
            preferences: preferences,
            cachedLyrics: cachedLyrics,
            storeCachedLyrics: storeCachedLyrics,
            now: now,
            appVersion: { "1.2.3" }
        )
    }
}

private actor LyricsAsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private enum LyricsTestError: Error {
    case notLoaded
}

private func lyricsResponse(
    _ request: URLRequest,
    contentType: String
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": contentType]
    )!
}

private func makeLyricsSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LyricsURLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private final class LyricsURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("LyricsURLProtocolStub handler was not configured")
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
