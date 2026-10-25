import AVFoundation
import Foundation
import XCTest

@testable import AonsokuKit

final class ReplayGainTests: XCTestCase {
    func testVolumeScaleUsesModesFallbacksPreampAndPeakClamp() {
        let tags = AudioReplayGain(
            trackGain: -4,
            trackPeak: 0.9,
            albumGain: -10,
            albumPeak: 0.8
        )
        let track = AudioReplayGainConfig(mode: .track)
        let album = AudioReplayGainConfig(mode: .album)

        XCTAssertEqual(track.volumeScale(for: tags), pow(10, -4 / 20), accuracy: 0.000_001)
        XCTAssertEqual(album.volumeScale(for: tags), pow(10, -10 / 20), accuracy: 0.000_001)

        let albumFallback = AudioReplayGain(albumGain: -8, albumPeak: 0.7)
        XCTAssertEqual(
            track.volumeScale(for: albumFallback),
            pow(10, -8 / 20),
            accuracy: 0.000_001
        )
        let trackFallback = AudioReplayGain(trackGain: -5, trackPeak: 0.75)
        XCTAssertEqual(
            album.volumeScale(for: trackFallback),
            pow(10, -5 / 20),
            accuracy: 0.000_001
        )

        let preamped = AudioReplayGainConfig(mode: .track, preAmp: 6, defaultGain: -9)
        XCTAssertEqual(
            preamped.volumeScale(for: AudioReplayGain(trackGain: -6)),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(preamped.volumeScale(for: nil), pow(10, -3 / 20), accuracy: 0.000_001)

        let clipping = AudioReplayGain(trackGain: 6, trackPeak: 0.8)
        XCTAssertEqual(track.volumeScale(for: clipping), 1.25, accuracy: 0.000_001)
    }

    @MainActor
    func testAudioServiceAppliesGainOnLoadAndConfigChange() async throws {
        let fixture = try PlayerStoreTestFixture()
        let players = LockedTestBox<[AVPlayer]>([])
        let audio = fixture.makeAudio { item in
            let player = AVPlayer(playerItem: item)
            players.update { $0.append(player) }
            return player
        }
        audio.setReplayGain(AudioReplayGainConfig(mode: .track, preAmp: 0, defaultGain: -6))
        audio.setContextQueue(
            songs: [fixture.queueSong("gain", replayGain: AudioReplayGain(trackGain: -6))],
            currentIndex: 0,
            autoplay: false
        )

        let loaded = await waitForPlayerStoreTest {
            players.read { !$0.isEmpty }
        }
        XCTAssertTrue(loaded)
        let attenuated = players.read { $0.last?.volume }
        XCTAssertEqual(
            try XCTUnwrap(attenuated),
            Float(pow(10.0, -6.0 / 20.0)),
            accuracy: 0.000_001
        )

        audio.setReplayGain(nil)
        let restored = await waitForPlayerStoreTest {
            players.read { $0.last?.volume == 1 }
        }
        XCTAssertTrue(restored)
        audio.shutdown()
    }
}
