import AVFoundation
import CoreGraphics
import ImageIO
import MediaPlayer
import UniformTypeIdentifiers
import XCTest
@testable import AonsokuKit

/// `AudioService` against the system-media seam: what Control Center, a Mac's
/// Now Playing menu and the media keys are told, and what they may ask for.
///
/// The seam is a recording fake here. The tests never touch the real
/// `MPNowPlayingInfoCenter` or `MPRemoteCommandCenter`, so running them cannot
/// take the media keys from whatever the person is listening to.
@MainActor
final class SystemMediaTests: XCTestCase {
    // MARK: Registration

    func testStartingRegistersTheCommandsOnce() throws {
        let fixture = try SystemMediaFixture(self)

        fixture.service.start()
        fixture.service.start()
        fixture.service.applicationWillEnterForeground()

        XCTAssertEqual(fixture.media.registrations, 1)
        XCTAssertEqual(fixture.media.activeRegistrations, 1)
    }

    func testShuttingDownStopsReceivingCommands() throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()

        fixture.service.shutdown()

        XCTAssertEqual(fixture.media.activeRegistrations, 0)
        XCTAssertNil(fixture.media.send(.play), "Nothing should be listening any more")
    }

    func testStartingAgainAfterShuttingDownRegistersAgain() throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        fixture.service.shutdown()

        fixture.service.start()

        XCTAssertEqual(fixture.media.registrations, 2)
        XCTAssertEqual(fixture.media.activeRegistrations, 1)
    }

    // MARK: What is published

    func testNothingIsPublishedUntilASongIsLoaded() throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()

        fixture.service.play()
        fixture.service.pause()
        fixture.service.stop()
        fixture.service.clearRemotePlaybackState()

        XCTAssertTrue(
            fixture.media.publications.isEmpty,
            "A card without a song would be blank and would claim the media keys"
        )
    }

    func testALoadedSongIsPublishedWithItsDescription() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()

        try await fixture.load()

        let entry = try XCTUnwrap(fixture.media.latest)
        XCTAssertEqual(entry.info.title, "Song one")
        XCTAssertEqual(entry.info.artist, "Artist")
        XCTAssertEqual(entry.info.album, "Album")
        XCTAssertEqual(try XCTUnwrap(entry.info.duration), 3, accuracy: 0.1)
        XCTAssertEqual(entry.info.elapsed, 0, accuracy: 0.1)
        XCTAssertEqual(entry.info.rate, 0)
        XCTAssertEqual(entry.state, .paused)
        XCTAssertNil(entry.info.artwork)
    }

    func testPlayingPublishesThePlayingStateAndPausingThePausedOne() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()

        XCTAssertEqual(fixture.media.send(.play), .success)
        let playing = await fixture.waitForState(.playing)
        XCTAssertTrue(playing, "The play command never published the playing state")

        XCTAssertEqual(fixture.media.send(.pause), .success)
        let paused = await fixture.waitForState(.paused)
        XCTAssertTrue(paused, "The pause command never published the paused state")
        XCTAssertEqual(fixture.service.playbackSnapshot().state, .paused)
        XCTAssertEqual(fixture.media.latest?.info.rate, 0)
    }

    func testTheToggleCommandAlternatesBetweenPlayingAndPaused() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()

        XCTAssertEqual(fixture.media.send(.togglePlayPause), .success)
        let playing = await fixture.waitForState(.playing)
        XCTAssertTrue(playing)

        XCTAssertEqual(fixture.media.send(.togglePlayPause), .success)
        let paused = await fixture.waitForState(.paused)
        XCTAssertTrue(paused)
    }

    func testNextAndPreviousMoveThroughTheQueueAndPublishTheNewSong() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()

        XCTAssertEqual(fixture.media.send(.nextTrack), .success)
        let second = await fixture.waitForTitle("Song two")
        XCTAssertTrue(second, "The next command never published the second song")

        XCTAssertEqual(fixture.media.send(.previousTrack), .success)
        let first = await fixture.waitForTitle("Song one")
        XCTAssertTrue(first, "The previous command never published the first song")
    }

    func testTheScrubberSeeksAndPublishesTheNewPosition() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()

        XCTAssertEqual(fixture.media.send(.changePlaybackPosition(2)), .success)

        let moved = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            (fixture.media.latest?.info.elapsed ?? 0) > 1.5
        }
        XCTAssertTrue(moved, "The scrubber never moved the published position")
        XCTAssertEqual(
            try XCTUnwrap(fixture.media.latest).info.elapsed, 2, accuracy: 0.3
        )
    }

    func testTheLikeCommandTogglesTheSongAndTheLikeIndicator() async throws {
        let fixture = try SystemMediaFixture(self)
        let songs = SongRepository(db: fixture.database.manager.dbPool)
        try songs.upsert(makeSongRecord("one"))
        fixture.service.start()
        try await fixture.load()

        XCTAssertEqual(fixture.media.send(.toggleLike), .success)
        let liked = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            fixture.media.likeStates.last == true
        }
        XCTAssertTrue(liked, "The indicator never showed the song as liked")
        XCTAssertNotNil(try songs.getById("one")?.starredAt)

        XCTAssertEqual(fixture.media.send(.toggleLike), .success)
        let unliked = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            fixture.media.likeStates.last == false
        }
        XCTAssertTrue(unliked, "The indicator never showed the song as not liked")
        XCTAssertNil(try songs.getById("one")?.starredAt)
    }

    // MARK: Another device

    func testControllingAnotherDeviceShowsItAndSendsItTheCommands() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()
        let stateBefore = fixture.service.playbackSnapshot().state

        fixture.service.updateRemotePlaybackState(.makeForTest(
            title: "Remote song", isPlaying: true, position: 42, duration: 200
        ))

        let shown = await waitForPlayerStoreTest {
            fixture.media.latest?.info.title == "Remote song"
        }
        XCTAssertTrue(shown, "The controlled device's song was never published")
        let entry = try XCTUnwrap(fixture.media.latest)
        XCTAssertEqual(entry.state, .playing)
        XCTAssertEqual(entry.info.elapsed, 42)
        XCTAssertEqual(entry.info.duration, 200)
        XCTAssertEqual(entry.info.rate, 1)

        // The device cannot be reached, so the command fails and nothing
        // happens to the playback here.
        XCTAssertEqual(fixture.media.send(.play), .failed)
        XCTAssertEqual(fixture.service.playbackSnapshot().state, stateBefore)

        fixture.service.clearRemotePlaybackState()
        let back = await waitForPlayerStoreTest { fixture.media.latest?.info.title == "Song one" }
        XCTAssertTrue(back, "The local song was never published again")
        XCTAssertEqual(fixture.media.latest?.state, .paused)
    }

    func testEndingRemoteControlWithNothingLoadedWithdrawsTheEntry() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        fixture.service.updateRemotePlaybackState(.makeForTest(
            title: "Remote song", isPlaying: true, position: 1, duration: 100
        ))
        let shown = await waitForPlayerStoreTest { fixture.media.latest != nil }
        XCTAssertTrue(shown)

        fixture.service.clearRemotePlaybackState()

        let withdrawn = await waitForPlayerStoreTest { fixture.media.last?.info == nil }
        XCTAssertTrue(withdrawn, "The entry outlived the remote control session")
        XCTAssertEqual(fixture.media.last?.state, .stopped)
    }

    // MARK: Withdrawing

    func testClearingWithdrawsTheEntryAndNothingBringsItBack() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()

        fixture.service.clear()

        let last = try XCTUnwrap(fixture.media.last)
        XCTAssertNil(last.info)
        XCTAssertEqual(last.state, .stopped)

        let count = fixture.media.publications.count
        fixture.service.stop()
        fixture.service.pause()
        fixture.service.seek(to: 1)
        XCTAssertEqual(
            fixture.media.publications.count, count,
            "A playback event after clear() published an entry again"
        )
    }

    func testShuttingDownWithdrawsTheEntry() async throws {
        let fixture = try SystemMediaFixture(self)
        fixture.service.start()
        try await fixture.load()

        fixture.service.shutdown()

        let last = try XCTUnwrap(fixture.media.last)
        XCTAssertNil(last.info)
        XCTAssertEqual(last.state, .stopped)
    }

    // MARK: Artwork

    func testACachedCoverIsPublishedAsAnImage() async throws {
        let fixture = try SystemMediaFixture(self)
        let cache = ImageCacheManager(
            db: fixture.database.manager.dbPool,
            storage: fixture.storage
        )
        _ = try cache.storeCoverImage(
            coverArtId: "cover-1",
            data: try makePNGData(side: 8),
            contentType: "image/png",
            coverSize: "800"
        )
        fixture.service.start()

        try await fixture.load(coverArtId: "cover-1")

        let arrived = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            fixture.media.latest?.info.artwork != nil
        }
        XCTAssertTrue(arrived, "The cached cover never reached the system")
        let artwork = try XCTUnwrap(fixture.media.latest?.info.artwork)
        XCTAssertEqual(artwork.platformCGImage?.width, 8)
        XCTAssertEqual(fixture.media.latest?.info.title, "Song one")
    }

    func testArtworkThatArrivesLateDoesNotWindTheClockBack() async throws {
        let gate = ArtworkGate()
        let png = try makePNGData(side: 4)
        let client = HTTPClient { request in
            await gate.wait()
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            ))
            return (png, response)
        }
        let fixture = try SystemMediaFixture(self, artworkClient: client)
        fixture.service.start()
        try await fixture.load()

        // The entry goes out at 0:00, then the artwork request waits.
        fixture.service.updateMetadata(AudioMetadata(
            title: "Song one",
            artist: "Artist",
            album: "Album",
            duration: 3,
            artworkUrl: "https://artwork.example/cover.png"
        ))
        let published = await waitForPlayerStoreTest {
            fixture.media.latest?.info.elapsed == 0
        }
        XCTAssertTrue(published)
        XCTAssertNil(fixture.media.latest?.info.artwork)

        // Playback moves on while the request waits. Nothing republishes the
        // entry for that, as when a song simply plays: the system counts on
        // from the last position it was given.
        let publicationsBefore = fixture.media.publications.count
        let player = try XCTUnwrap(fixture.currentPlayer)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
        XCTAssertEqual(fixture.media.publications.count, publicationsBefore)
        XCTAssertEqual(try XCTUnwrap(fixture.media.latest).info.elapsed, 0, accuracy: 0.1)

        await gate.open()
        let arrived = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            fixture.media.latest?.info.artwork != nil
        }

        XCTAssertTrue(arrived, "The late artwork never reached the system")
        XCTAssertEqual(
            try XCTUnwrap(fixture.media.latest).info.elapsed, 2, accuracy: 0.3,
            "The entry with the artwork carried the position of its first publication"
        )
    }

    // MARK: The entry the system receives

    func testTheEntryOmitsEmptyTextAndAnUnknownDuration() {
        let entry = MediaPlayerSystemMedia.dictionary(
            for: SystemNowPlayingInfo(
                title: "",
                artist: nil,
                album: "Album",
                duration: 0,
                elapsed: 5,
                rate: 1,
                artwork: nil
            ),
            artwork: nil
        )

        XCTAssertNil(entry[MPMediaItemPropertyTitle])
        XCTAssertNil(entry[MPMediaItemPropertyArtist])
        XCTAssertEqual(entry[MPMediaItemPropertyAlbumTitle] as? String, "Album")
        XCTAssertNil(entry[MPMediaItemPropertyPlaybackDuration])
        XCTAssertEqual(entry[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 5)
        XCTAssertEqual(entry[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(entry[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)
    }

    func testPositionsThatAreNotNumbersAreClamped() {
        func entry(elapsed: Double, rate: Double, duration: Double?) -> [String: Any] {
            MediaPlayerSystemMedia.dictionary(
                for: SystemNowPlayingInfo(
                    title: "Song",
                    artist: nil,
                    album: nil,
                    duration: duration,
                    elapsed: elapsed,
                    rate: rate,
                    artwork: nil
                ),
                artwork: nil
            )
        }

        let nan = entry(elapsed: .nan, rate: .infinity, duration: .nan)
        XCTAssertEqual(nan[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertEqual(nan[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertNil(nan[MPMediaItemPropertyPlaybackDuration])

        let negative = entry(elapsed: -4, rate: -1, duration: -10)
        XCTAssertEqual(negative[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertEqual(negative[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertNil(negative[MPMediaItemPropertyPlaybackDuration])
    }

    func testTheEntryHoldsOnlyTextNumbersAndArtwork() throws {
        let image = try XCTUnwrap(
            PlatformImage(data: try makePNGData(side: 2))
        )
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        let entry = MediaPlayerSystemMedia.dictionary(
            for: SystemNowPlayingInfo(
                title: "Song",
                artist: "Artist",
                album: "Album",
                duration: 180,
                elapsed: 10,
                rate: 1,
                artwork: image
            ),
            artwork: artwork
        )

        // No URL is ever handed over, so no credential can be in the entry.
        for (key, value) in entry {
            XCTAssertTrue(
                value is String || value is Double || value is MPMediaItemArtwork,
                "\(key) holds a \(type(of: value))"
            )
        }
        XCTAssertNotNil(entry[MPMediaItemPropertyArtwork])
    }

    func testPlaybackStatesMapToTheSystemsStates() {
        XCTAssertEqual(MediaPlayerSystemMedia.playbackState(for: .playing), .playing)
        XCTAssertEqual(MediaPlayerSystemMedia.playbackState(for: .paused), .paused)
        XCTAssertEqual(MediaPlayerSystemMedia.playbackState(for: .stopped), .stopped)
    }

    // MARK: The platform session

    func testATestProcessNeverGetsTheRealSystemSessionOnAMac() {
        #if os(macOS)
        let detached = PlatformSystemMedia.makeSession(isTestProcess: true)
        XCTAssertTrue(detached is DetachedSystemMedia)
        // It takes everything and shows and receives nothing.
        detached.publish(nil, state: .stopped)
        detached.setLikeActive(true)
        let token = detached.startReceivingCommands { _ in .success }
        token.cancel()
        token.cancel()

        // The real session is only built here, never driven.
        XCTAssertTrue(
            PlatformSystemMedia.makeSession(isTestProcess: false)
                is MediaPlayerSystemMedia
        )
        // Under XCTest the default is the detached session, so no AudioService
        // a test builds can take the media keys from the person's music.
        XCTAssertTrue(PlatformSystemMedia.makeSession() is DetachedSystemMedia)
        #else
        // iOS keeps the media center, which the Simulator provides to tests.
        XCTAssertTrue(PlatformSystemMedia.makeSession() is MediaPlayerSystemMedia)
        #endif
    }
}

// MARK: - Fixtures

@MainActor
private final class SystemMediaFixture {
    let service: AudioService
    let media: FakeSystemMedia
    let database: TemporaryDatabase
    let storage: StorageLayout
    private let songURLs: [URL]
    private let players = LockedTestBox<[AVPlayer]>([])

    init(
        _ test: XCTestCase,
        artworkClient: HTTPClient = HTTPClient { _ in throw URLError(.notConnectedToInternet) }
    ) throws {
        let database = try TemporaryDatabase()
        let storage = StorageLayout.macOS(
            root: database.directory.appendingPathComponent("data", isDirectory: true)
        )
        var urls: [URL] = []
        for name in ["one", "two"] {
            let url = database.directory.appendingPathComponent("\(name).wav")
            try makeSilentWAVData(duration: 3).write(to: url)
            urls.append(url)
        }
        let media = FakeSystemMedia()
        let players = players
        let service = AudioService(
            databaseManager: database.manager,
            storage: storage,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            playerFactory: { item in
                let player = AVPlayer(playerItem: item)
                players.update { $0.append(player) }
                return player
            },
            artworkClient: artworkClient,
            audioSession: QuietAudioSession(),
            volumeControl: QuietVolumeControl(),
            systemMedia: media
        )
        self.database = database
        self.storage = storage
        self.songURLs = urls
        self.media = media
        self.service = service
        test.addTeardownBlock { service.shutdown() }
    }

    /// Queues "Song one" and "Song two", starts on the first paused, and waits
    /// until the system has been told about it.
    func load(coverArtId: String? = nil) async throws {
        let songs = zip(["one", "two"], songURLs).enumerated().map { index, entry in
            QueueSong(
                id: entry.0,
                title: "Song \(entry.0)",
                artist: "Artist",
                album: "Album",
                duration: 3,
                coverArtId: index == 0 ? coverArtId : nil,
                streamUrl: entry.1.absoluteString,
                cachedFileUri: entry.1.absoluteString
            )
        }
        service.setContextQueue(songs: songs, currentIndex: 0, autoplay: false)
        let loaded = await waitForPlayerStoreTest(timeout: .seconds(5)) { [players] in
            players.read { !$0.isEmpty }
        }
        XCTAssertTrue(loaded, "The player was never created")
        let published = await waitForPlayerStoreTest(timeout: .seconds(5)) { [media] in
            media.latest != nil
        }
        XCTAssertTrue(published, "The system was never told about the song")
    }

    /// The player the service created, for moving it without the service.
    var currentPlayer: AVPlayer? { players.read { $0.last } }

    func waitForState(_ state: SystemPlaybackState) async -> Bool {
        await waitForPlayerStoreTest(timeout: .seconds(5)) { [media] in
            media.latest?.state == state
        }
    }

    func waitForTitle(_ title: String) async -> Bool {
        await waitForPlayerStoreTest(timeout: .seconds(5)) { [media] in
            media.latest?.info.title == title
        }
    }
}

/// Records what the app tells the system and lets a test press a media key.
private final class FakeSystemMedia: SystemMediaSession, @unchecked Sendable {
    struct Publication {
        let info: SystemNowPlayingInfo?
        let state: SystemPlaybackState
    }

    private let lock = NSLock()
    private var recorded: [Publication] = []
    private var handlers: [Int: SystemMediaCommandHandler] = [:]
    private var registered = 0
    private var likes: [Bool] = []

    var publications: [Publication] { lock.withLock { recorded } }
    var last: Publication? { publications.last }

    /// The last entry that is not a withdrawal, if it is the current one.
    var latest: (info: SystemNowPlayingInfo, state: SystemPlaybackState)? {
        guard let last, let info = last.info else { return nil }
        return (info, last.state)
    }

    var registrations: Int { lock.withLock { registered } }
    var activeRegistrations: Int { lock.withLock { handlers.count } }
    var likeStates: [Bool] { lock.withLock { likes } }

    func publish(_ info: SystemNowPlayingInfo?, state: SystemPlaybackState) {
        lock.withLock { recorded.append(Publication(info: info, state: state)) }
    }

    func setLikeActive(_ active: Bool) {
        lock.withLock { likes.append(active) }
    }

    func startReceivingCommands(
        _ handler: @escaping SystemMediaCommandHandler
    ) -> ObservationToken {
        let id: Int = lock.withLock {
            registered += 1
            handlers[registered] = handler
            return registered
        }
        return ObservationToken { [weak self] in
            self?.lock.withLock { _ = self?.handlers.removeValue(forKey: id) }
        }
    }

    /// Presses a key. Nil when nothing is listening.
    @discardableResult
    func send(_ command: SystemMediaCommand) -> SystemMediaCommandResult? {
        let handler = lock.withLock { handlers.keys.max().flatMap { handlers[$0] } }
        return handler?(command)
    }
}

private final class QuietAudioSession: PlaybackAudioSession, @unchecked Sendable {
    let pausesWhenOutputDisappears = true
    func configure() throws {}
    func activate() throws {}
    func deactivate() {}

    func observeInterruptions(
        _ handler: @escaping @Sendable (AudioInterruptionEvent) -> Void
    ) -> ObservationToken {
        ObservationToken {}
    }

    func observeRouteChanges(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) -> ObservationToken {
        ObservationToken {}
    }
}

private final class QuietVolumeControl: OutputVolumeControlling, @unchecked Sendable {
    let playerGain: Float = 1
    private(set) var volume: Float = 1

    func startObserving(_ handler: @escaping @Sendable (Float) -> Void) {}
    func stopObserving() {}

    func set(
        _ value: Float,
        completion: @escaping (Result<Float, AudioServiceError>) -> Void
    ) {
        volume = value
        completion(.success(value))
    }

    func setHostView(_ view: PlatformView?) {}
    func setHUDEnabled(_ enabled: Bool) {}
}

/// Holds an HTTP answer back until the test lets it through.
private actor ArtworkGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private extension AudioRemotePlaybackProjection {
    static func makeForTest(
        title: String,
        isPlaying: Bool,
        position: Double,
        duration: Double
    ) -> AudioRemotePlaybackProjection {
        AudioRemotePlaybackProjection(
            metadata: AudioMetadata(title: title, artist: "Remote artist", album: "Remote album"),
            isPlaying: isPlaying,
            position: position,
            duration: duration,
            isShuffleActive: false,
            repeatMode: .off,
            volume: nil,
            targetDeviceId: nil,
            expectedGeneration: nil
        )
    }
}

/// A square PNG, for artwork that has to decode.
private func makePNGData(side: Int) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}
