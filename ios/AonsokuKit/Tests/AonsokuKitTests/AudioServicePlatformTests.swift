import AVFoundation
import XCTest
@testable import AonsokuKit

/// `AudioService` against the platform seams: the audio session and the output
/// volume. Both are fakes here, so every platform runs the same expectations
/// for the iOS behavior (the system pauses and owns the volume) and the macOS
/// behavior (the service pauses and the app owns the volume).
@MainActor
final class AudioServicePlatformTests: XCTestCase {
    private let replayGain = Float(pow(10.0, -6.0 / 20.0))

    // MARK: Volume

    func testPlayerVolumeIsReplayGainTimesTheAppVolume() async throws {
        let fixture = try AudioPlatformFixture(self, volume: makeAppVolume())
        fixture.service.setReplayGain(
            AudioReplayGainConfig(mode: .track, preAmp: 0, defaultGain: -6)
        )
        try await fixture.load(gain: -6)
        XCTAssertEqual(try fixture.playerVolume(), replayGain, accuracy: 0.000_001)

        let result = await fixture.setSystemVolume(0.5)

        XCTAssertEqual(try result.get(), 0.5)
        XCTAssertEqual(fixture.service.systemVolume, 0.5)
        XCTAssertEqual(try fixture.playerVolume(), replayGain * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(fixture.volumeEvents, [0.5])
    }

    func testASongLoadedAfterTheVolumeChangeStartsAtThatVolume() async throws {
        let fixture = try AudioPlatformFixture(self, volume: makeAppVolume())
        fixture.service.setReplayGain(
            AudioReplayGainConfig(mode: .track, preAmp: 0, defaultGain: -6)
        )
        _ = await fixture.setSystemVolume(0.25)

        try await fixture.load(gain: -6)

        XCTAssertEqual(try fixture.playerVolume(), replayGain * 0.25, accuracy: 0.000_001)
    }

    func testTheAppVolumeSurvivesTurningReplayGainOff() async throws {
        let fixture = try AudioPlatformFixture(self, volume: makeAppVolume())
        fixture.service.setReplayGain(
            AudioReplayGainConfig(mode: .track, preAmp: 0, defaultGain: -6)
        )
        try await fixture.load(gain: -6)
        _ = await fixture.setSystemVolume(0.5)

        fixture.service.setReplayGain(nil)

        XCTAssertEqual(try fixture.playerVolume(), 0.5, accuracy: 0.000_001)
    }

    func testTheAppVolumeIsAppliedAtFullReplayGain() async throws {
        let fixture = try AudioPlatformFixture(self, volume: makeAppVolume())
        _ = await fixture.setSystemVolume(0.4)

        try await fixture.load(gain: nil)

        XCTAssertEqual(try fixture.playerVolume(), 0.4, accuracy: 0.000_001)
    }

    func testASystemOwnedVolumeNeverScalesThePlayer() async throws {
        let control = FakeVolumeControl(volume: 0.3, playerGain: 1)
        let fixture = try AudioPlatformFixture(self, volume: control)
        fixture.service.setReplayGain(
            AudioReplayGainConfig(mode: .track, preAmp: 0, defaultGain: -6)
        )
        try await fixture.load(gain: -6)
        XCTAssertEqual(fixture.service.systemVolume, 0.3)

        let result = await fixture.setSystemVolume(0.7)

        XCTAssertEqual(try result.get(), 0.7)
        XCTAssertEqual(control.requested, [0.7])
        XCTAssertEqual(try fixture.playerVolume(), replayGain, accuracy: 0.000_001)
    }

    func testRequestedVolumesAreClampedBeforeReachingTheControl() async throws {
        let control = FakeVolumeControl(volume: 0.5, playerGain: 1)
        let fixture = try AudioPlatformFixture(self, volume: control)

        _ = await fixture.setSystemVolume(3)
        _ = await fixture.setSystemVolume(-1)

        XCTAssertEqual(control.requested, [1, 0])
    }

    func testAFailedVolumeChangeIsReportedWithoutAnEvent() async throws {
        let control = FakeVolumeControl(volume: 0.5, playerGain: 1)
        let failure = AudioServiceError(code: "volume_control_unavailable", message: "No slider.")
        control.failure = failure
        let fixture = try AudioPlatformFixture(self, volume: control)

        let result = await fixture.setSystemVolume(0.2)

        guard case .failure(let error) = result else {
            return XCTFail("Expected the failure to reach the caller")
        }
        XCTAssertEqual(error, failure)
        XCTAssertEqual(fixture.volumeEvents, [])
    }

    func testStartingHandsTheHostViewToTheVolumeControl() throws {
        let control = FakeVolumeControl(volume: 0.5, playerGain: 1)
        let fixture = try AudioPlatformFixture(self, volume: control)
        let host = PlatformView()

        fixture.service.start(volumeHostView: host)

        XCTAssertTrue(control.hostViews.last.flatMap { $0 } === host)
    }

    func testVolumeHUDPreferenceReachesTheVolumeControl() throws {
        let control = FakeVolumeControl(volume: 0.5, playerGain: 1)
        let fixture = try AudioPlatformFixture(self, volume: control)

        fixture.service.setVolumeHUDEnabled(false)
        fixture.service.setVolumeHUDEnabled(true)

        XCTAssertEqual(control.hudStates, [false, true])
    }

    func testVolumeChangesFromOutsideTheAppArePublishedWhileStarted() throws {
        let control = FakeVolumeControl(volume: 0.5, playerGain: 1)
        let fixture = try AudioPlatformFixture(self, volume: control)
        XCTAssertFalse(control.isObserving)

        fixture.service.start()
        XCTAssertTrue(control.isObserving)
        control.simulateExternalChange(0.8)

        XCTAssertEqual(fixture.volumeEvents, [0.8])

        fixture.service.shutdown()
        XCTAssertFalse(control.isObserving)
    }

    // MARK: Audio session

    func testStartingConfiguresTheSessionAndWatchesItsEvents() throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        XCTAssertFalse(session.isObserving)

        fixture.service.start()

        XCTAssertGreaterThanOrEqual(session.configureCount, 1)
        XCTAssertTrue(session.isObserving)
    }

    func testShuttingDownStopsWatchingTheSession() throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()

        fixture.service.shutdown()

        XCTAssertFalse(session.isObserving)
        XCTAssertGreaterThanOrEqual(session.deactivateCount, 1)
    }

    func testPlayingTakesAudioFocus() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        try await fixture.load(gain: nil)
        let before = session.activateCount

        fixture.service.play()

        XCTAssertEqual(session.activateCount, before + 1)
    }

    func testAnActivationFailureIsReportedAndFailsPlayback() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        try await fixture.load(gain: nil)
        session.activationError = NSError(domain: "AudioSessionTests", code: 561_015_905)

        fixture.service.play()

        XCTAssertEqual(fixture.errorCodes, ["audio_session_failed"])
        XCTAssertEqual(fixture.service.playbackSnapshot().state, .failed)
    }

    // MARK: Losing the output device

    func testLosingTheOutputPausesPlaybackWhereTheSystemDoesNot() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()
        try await fixture.load(gain: nil, autoplay: true)

        session.sendRouteChange(.oldDeviceUnavailable)

        XCTAssertEqual(fixture.service.playbackSnapshot().state, .paused)
        XCTAssertEqual(fixture.routeReasons, ["oldDeviceUnavailable"])
        XCTAssertEqual(fixture.states.last, .paused)
    }

    func testLosingTheOutputLeavesPlaybackToTheSystemWhenItPausesItself() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: false)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()
        try await fixture.load(gain: nil, autoplay: true)
        let pausesBefore = fixture.states.filter { $0 == .paused }.count

        session.sendRouteChange(.oldDeviceUnavailable)

        XCTAssertNotEqual(fixture.service.playbackSnapshot().state, .paused)
        XCTAssertEqual(fixture.states.filter { $0 == .paused }.count, pausesBefore)
        XCTAssertEqual(fixture.routeReasons, ["oldDeviceUnavailable"])
    }

    func testOtherRouteChangesNeverPause() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()
        try await fixture.load(gain: nil, autoplay: true)

        for reason in [
            AudioRouteChangeReason.newDeviceAvailable, .override, .categoryChange,
            .routeConfigurationChange, .noSuitableRouteForCategory, .wakeFromSleep, .unknown,
        ] {
            session.sendRouteChange(reason)
        }

        XCTAssertNotEqual(fixture.service.playbackSnapshot().state, .paused)
        XCTAssertFalse(fixture.states.contains(.paused))
        XCTAssertEqual(fixture.routeReasons.count, 7)
    }

    func testLosingTheOutputPausesEvenWhileTheAppIsInTheBackground() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()
        try await fixture.load(gain: nil, autoplay: true)
        fixture.service.applicationDidEnterBackground()

        session.sendRouteChange(.oldDeviceUnavailable)

        XCTAssertEqual(fixture.service.playbackSnapshot().state, .paused)
        // Nobody is watching, so the change is not published.
        XCTAssertEqual(fixture.routeReasons, [])
    }

    // MARK: Interruptions

    func testAnInterruptionPausesPlaybackAndIsPublished() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()
        try await fixture.load(gain: nil, autoplay: true)

        session.sendInterruption(.began)

        XCTAssertEqual(fixture.service.playbackSnapshot().state, .paused)
        XCTAssertEqual(fixture.interruptions, ["began"])
    }

    func testTheEndOfAnInterruptionIsPublishedWithItsResumeHint() async throws {
        let session = FakePlaybackAudioSession(pausesWhenOutputDisappears: true)
        let fixture = try AudioPlatformFixture(self, session: session)
        fixture.service.start()
        try await fixture.load(gain: nil)

        session.sendInterruption(.ended(shouldResume: false))
        session.sendInterruption(.ended(shouldResume: true))

        XCTAssertEqual(fixture.interruptions, ["ended:false", "ended:true"])
    }

    // MARK: Helpers

    private func makeAppVolume() throws -> AppVolumeControl {
        let name = "aonsoku-audio-platform-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppVolumeControl(defaults: defaults)
    }
}

// MARK: - Fixtures

@MainActor
private final class AudioPlatformFixture {
    let service: AudioService
    let session: FakePlaybackAudioSession
    private let database: TemporaryDatabase
    private let songURL: URL
    private let players = LockedTestBox<[AVPlayer]>([])
    private let events = LockedTestBox<[AudioServiceEvent]>([])

    init(
        _ test: XCTestCase,
        session: FakePlaybackAudioSession = FakePlaybackAudioSession(
            pausesWhenOutputDisappears: true
        ),
        volume: OutputVolumeControlling = FakeVolumeControl(volume: 1, playerGain: 1)
    ) throws {
        let database = try TemporaryDatabase()
        let songURL = database.directory.appendingPathComponent("tone.wav")
        try makeSilentWAVData(duration: 3).write(to: songURL)
        let players = players
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            playerFactory: { item in
                let player = AVPlayer(playerItem: item)
                players.update { $0.append(player) }
                return player
            },
            audioSession: session,
            volumeControl: volume
        )
        let events = events
        service.subscribe { event in events.update { $0.append(event) } }
        self.database = database
        self.songURL = songURL
        self.session = session
        self.service = service
        test.addTeardownBlock { service.shutdown() }
    }

    /// Loads the one song and waits until its player exists.
    func load(gain: Double?, autoplay: Bool = false) async throws {
        let song = QueueSong(
            id: "tone",
            title: "Song tone",
            artist: "Artist",
            album: "Album",
            duration: 3,
            streamUrl: songURL.absoluteString,
            cachedFileUri: songURL.absoluteString,
            replayGain: gain.map { AudioReplayGain(trackGain: $0) }
        )
        service.setContextQueue(songs: [song], currentIndex: 0, autoplay: autoplay)
        let loaded = await waitForPlayerStoreTest(timeout: .seconds(5)) { [players] in
            players.read { !$0.isEmpty }
        }
        XCTAssertTrue(loaded, "The player was never created")
        let ready = await waitForPlayerStoreTest(timeout: .seconds(5)) { [service] in
            service.playbackSnapshot().state != .idle
        }
        XCTAssertTrue(ready, "Playback never left the idle state")
    }

    func playerVolume() throws -> Float {
        try XCTUnwrap(players.read { $0.last }).volume
    }

    func setSystemVolume(_ value: Double) async -> Result<Float, AudioServiceError> {
        await withCheckedContinuation { continuation in
            service.setSystemVolume(value) { continuation.resume(returning: $0) }
        }
    }

    var volumeEvents: [Float] {
        events.read {
            $0.compactMap { event in
                guard case .systemVolumeChanged(let volume) = event else { return nil }
                return volume
            }
        }
    }

    var routeReasons: [String] {
        events.read {
            $0.compactMap { event in
                guard case .routeChanged(let reason) = event else { return nil }
                return reason
            }
        }
    }

    var states: [AudioPlaybackSnapshot.State] {
        events.read {
            $0.compactMap { event in
                guard case .playbackStateChanged(let state, _) = event else { return nil }
                return state
            }
        }
    }

    var errorCodes: [String] {
        events.read {
            $0.compactMap { event in
                guard case .error(let code, _, _) = event else { return nil }
                return code
            }
        }
    }

    var interruptions: [String] {
        events.read {
            $0.compactMap { event in
                guard case .interruptionChanged(let type, let shouldResume) = event else {
                    return nil
                }
                return shouldResume.map { "\(type):\($0)" } ?? type
            }
        }
    }
}

private final class FakePlaybackAudioSession: PlaybackAudioSession, @unchecked Sendable {
    let pausesWhenOutputDisappears: Bool
    var activationError: Error? {
        get { lock.withLock { storedActivationError } }
        set { lock.withLock { storedActivationError = newValue } }
    }

    private let lock = NSLock()
    private var storedActivationError: Error?
    private var configures = 0
    private var activations = 0
    private var deactivations = 0
    private var interruptionHandler: (@Sendable (AudioInterruptionEvent) -> Void)?
    private var routeHandler: (@Sendable (AudioRouteChangeReason) -> Void)?

    init(pausesWhenOutputDisappears: Bool) {
        self.pausesWhenOutputDisappears = pausesWhenOutputDisappears
    }

    var configureCount: Int { lock.withLock { configures } }
    var activateCount: Int { lock.withLock { activations } }
    var deactivateCount: Int { lock.withLock { deactivations } }
    var isObserving: Bool {
        lock.withLock { interruptionHandler != nil && routeHandler != nil }
    }

    func configure() throws { lock.withLock { configures += 1 } }

    func activate() throws {
        if let error = activationError { throw error }
        lock.withLock { activations += 1 }
    }

    func deactivate() { lock.withLock { deactivations += 1 } }

    func observeInterruptions(
        _ handler: @escaping @Sendable (AudioInterruptionEvent) -> Void
    ) -> ObservationToken {
        lock.withLock { interruptionHandler = handler }
        return ObservationToken { [weak self] in
            self?.lock.withLock { self?.interruptionHandler = nil }
        }
    }

    func observeRouteChanges(
        _ handler: @escaping @Sendable (AudioRouteChangeReason) -> Void
    ) -> ObservationToken {
        lock.withLock { routeHandler = handler }
        return ObservationToken { [weak self] in
            self?.lock.withLock { self?.routeHandler = nil }
        }
    }

    func sendInterruption(_ event: AudioInterruptionEvent) {
        let handler = lock.withLock { interruptionHandler }
        handler?(event)
    }

    func sendRouteChange(_ reason: AudioRouteChangeReason) {
        let handler = lock.withLock { routeHandler }
        handler?(reason)
    }
}

private final class FakeVolumeControl: OutputVolumeControlling, @unchecked Sendable {
    let playerGain: Float
    var failure: AudioServiceError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    private let lock = NSLock()
    private var current: Float
    private var storedFailure: AudioServiceError?
    private var observer: (@Sendable (Float) -> Void)?
    private var asked: [Float] = []
    private var hosts: [PlatformView?] = []
    private var huds: [Bool] = []

    init(volume: Float, playerGain: Float) {
        current = volume
        self.playerGain = playerGain
    }

    var volume: Float { lock.withLock { current } }
    var requested: [Float] { lock.withLock { asked } }
    var hostViews: [PlatformView?] { lock.withLock { hosts } }
    var hudStates: [Bool] { lock.withLock { huds } }
    var isObserving: Bool { lock.withLock { observer != nil } }

    func startObserving(_ handler: @escaping @Sendable (Float) -> Void) {
        lock.withLock { observer = handler }
    }

    func stopObserving() { lock.withLock { observer = nil } }

    func set(
        _ value: Float,
        completion: @escaping (Result<Float, AudioServiceError>) -> Void
    ) {
        let outcome: Result<Float, AudioServiceError> = lock.withLock {
            asked.append(value)
            if let storedFailure { return .failure(storedFailure) }
            current = value
            return .success(value)
        }
        completion(outcome)
    }

    func setHostView(_ view: PlatformView?) { lock.withLock { hosts.append(view) } }

    func setHUDEnabled(_ enabled: Bool) { lock.withLock { huds.append(enabled) } }

    /// A hardware volume button, as the system reports it.
    func simulateExternalChange(_ value: Float) {
        let handler = lock.withLock { () -> (@Sendable (Float) -> Void)? in
            current = value
            return observer
        }
        handler?(value)
    }
}
