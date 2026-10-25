import AVFoundation
import Foundation
import XCTest

@testable import AonsokuKit

@MainActor
final class GaplessPlaybackTests: XCTestCase {
    func testAutomaticAdvanceAdoptsPreloadedItemWithoutLoadingFlicker() async throws {
        let database = try TemporaryDatabase()
        let firstURL = database.directory.appendingPathComponent("first.wav")
        let secondURL = database.directory.appendingPathComponent("second.wav")
        try makeSilentWAVData(duration: 3).write(to: firstURL)
        try makeSilentWAVData(duration: 3).write(to: secondURL)

        let songs = [
            queueSong("first", url: firstURL, gain: -3),
            queueSong("second", url: secondURL, gain: -12),
        ]
        var queuePlayer: AVQueuePlayer?
        var playerCreations = 0
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            playerFactory: { item in
                playerCreations += 1
                let player = AVQueuePlayer(items: [item])
                queuePlayer = player
                return player
            }
        )
        service.setReplayGain(AudioReplayGainConfig(mode: .track))
        service.setContextQueue(
            songs: songs,
            currentIndex: 0,
            autoplay: false
        )

        let preloaded = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            service.playbackSnapshot().state == .paused &&
                queuePlayer?.items().count == 2
        }
        XCTAssertTrue(preloaded)
        let preloadedItem = try XCTUnwrap(queuePlayer?.items().last)
        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: queuePlayer?.currentItem
        )

        let advanced = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            service.fullState()?.currentSongId == "second" &&
                service.playbackSnapshot().metadata.title == "Song second" &&
                queuePlayer?.currentItem === preloadedItem
        }

        XCTAssertTrue(advanced)
        XCTAssertEqual(playerCreations, 1)
        XCTAssertEqual(
            try XCTUnwrap(queuePlayer?.volume),
            Float(pow(10.0, -12.0 / 20.0)),
            accuracy: 0.000_001
        )
        service.shutdown()
    }

    func testQueueEditReplacesTheStagedNextItem() async throws {
        let database = try TemporaryDatabase()
        let firstURL = database.directory.appendingPathComponent("first.wav")
        let secondURL = database.directory.appendingPathComponent("second.wav")
        let queuedURL = database.directory.appendingPathComponent("queued.wav")
        for url in [firstURL, secondURL, queuedURL] {
            try makeSilentWAVData(duration: 3).write(to: url)
        }

        let first = queueSong("first", url: firstURL)
        let second = queueSong("second", url: secondURL)
        let queued = queueSong("queued", url: queuedURL)
        var queuePlayer: AVQueuePlayer?
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            playerFactory: { item in
                let player = AVQueuePlayer(items: [item])
                queuePlayer = player
                return player
            }
        )
        service.setContextQueue(
            songs: [first, second],
            currentIndex: 0,
            autoplay: false
        )
        let initiallyPreloaded = await waitForPlayerStoreTest(
            timeout: .seconds(60)
        ) {
            queuePlayer?.items().count == 2
        }
        XCTAssertTrue(initiallyPreloaded)

        service.addToUserQueue(songs: [queued], position: "next")

        let replaced = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            guard let item = queuePlayer?.items().last,
                  let asset = item.asset as? AVURLAsset else { return false }
            return queuePlayer?.items().count == 2 && asset.url == queuedURL
        }
        let queuedURLs = queuePlayer?.items().compactMap {
            ($0.asset as? AVURLAsset)?.url.lastPathComponent
        } ?? []
        XCTAssertTrue(replaced, "queued items: \(queuedURLs)")
        service.shutdown()
    }

    func testEndOfTrackSleepRemovesPreloadAndCancelRestoresIt() async throws {
        let database = try TemporaryDatabase()
        let firstURL = database.directory.appendingPathComponent("first.wav")
        let secondURL = database.directory.appendingPathComponent("second.wav")
        for url in [firstURL, secondURL] {
            try makeSilentWAVData(duration: 3).write(to: url)
        }

        var queuePlayer: AVQueuePlayer?
        let service = AudioService(
            databaseManager: database.manager,
            scrobbleBuffer: makeIsolatedScrobbleBuffer(),
            scrobbleSubmitter: makeIsolatedScrobbleSubmitter(),
            playerFactory: { item in
                let player = AVQueuePlayer(items: [item])
                queuePlayer = player
                return player
            }
        )
        service.setContextQueue(
            songs: [
                queueSong("first", url: firstURL),
                queueSong("second", url: secondURL),
            ],
            currentIndex: 0,
            autoplay: false
        )
        let initiallyPreloaded = await waitForPlayerStoreTest(
            timeout: .seconds(60)
        ) {
            queuePlayer?.items().count == 2 &&
                queuePlayer?.actionAtItemEnd == .advance
        }
        XCTAssertTrue(initiallyPreloaded)

        service.setSleepTimer(seconds: 0, mode: "endOfTrack")

        let removed = await waitForPlayerStoreTest {
            queuePlayer?.items().count == 1 &&
                queuePlayer?.actionAtItemEnd == .pause
        }
        XCTAssertTrue(removed)

        service.cancelSleepTimer()

        let restored = await waitForPlayerStoreTest(timeout: .seconds(5)) {
            queuePlayer?.items().count == 2 &&
                queuePlayer?.actionAtItemEnd == .advance
        }
        XCTAssertTrue(restored)
        service.shutdown()
    }

    private func queueSong(
        _ id: String,
        url: URL,
        gain: Double? = nil
    ) -> QueueSong {
        QueueSong(
            id: id,
            title: "Song \(id)",
            artist: "Artist",
            album: "Album",
            duration: 3,
            streamUrl: url.absoluteString,
            cachedFileUri: url.absoluteString,
            replayGain: gain.map { AudioReplayGain(trackGain: $0) }
        )
    }
}
