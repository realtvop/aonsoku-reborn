import XCTest
@testable import AonsokuNativePlugin

final class AudioAdapterTests: XCTestCase {
    func testSourcePayloadsPreserveEverySupportedKind() {
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeSource([
                "kind": "stream",
                "url": "https://example.test/song.mp3",
                "songId": "song-1",
            ]),
            .stream(url: "https://example.test/song.mp3", songId: "song-1")
        )
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeSource([
                "kind": "native-file",
                "uri": "file:///tmp/song.flac",
                "songId": "song-2",
            ]),
            .nativeFile(uri: "file:///tmp/song.flac", songId: "song-2")
        )
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeSource([
                "kind": "radio",
                "url": "https://radio.example.test/live",
                "radioId": "radio-1",
            ]),
            .radio(url: "https://radio.example.test/live", radioId: "radio-1")
        )
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeSource([
                "kind": "blob",
                "url": "blob:https://example.test/id",
                "songId": "song-3",
            ]),
            .blob(url: "blob:https://example.test/id", songId: "song-3")
        )
    }

    func testSourcePayloadRejectsMissingAndUnknownKinds() {
        XCTAssertNil(AonsokuNativeAudioPlugin.decodeSource(nil))
        XCTAssertNil(AonsokuNativeAudioPlugin.decodeSource(["kind": "stream"]))
        XCTAssertNil(AonsokuNativeAudioPlugin.decodeSource([
            "kind": "unsupported",
            "url": "https://example.test",
        ]))
    }

    func testMetadataPayloadPreservesContractFieldsAndNumericTypes() {
        let metadata = AonsokuNativeAudioPlugin.decodeMetadata([
            "title": "Title",
            "artist": "Artist",
            "album": "Album",
            "duration": NSNumber(value: 240.5),
            "artworkUrl": "https://example.test/cover.jpg",
            "coverArtId": "cover-1",
        ])

        XCTAssertEqual(metadata.title, "Title")
        XCTAssertEqual(metadata.artist, "Artist")
        XCTAssertEqual(metadata.album, "Album")
        XCTAssertEqual(metadata.duration, 240.5)
        XCTAssertEqual(metadata.artworkUrl, "https://example.test/cover.jpg")
        XCTAssertEqual(metadata.coverArtId, "cover-1")
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeMetadata(nil),
            AudioMetadata()
        )
    }

    func testRemoteCommandAllowlistMatchesCoordinationContract() {
        let supported = [
            "play", "pause", "toggle_play_pause", "previous", "next",
            "seek", "set_volume", "set_shuffle", "set_repeat",
            "toggle_like", "play_song", "play_album", "play_playlist",
            "add_to_queue_next", "add_to_queue_last", "remove_from_queue",
            "reorder_queue", "clear_queue", "play_at_index",
        ]

        for command in supported {
            XCTAssertTrue(
                AonsokuNativeAudioPlugin.isSupportedRemoteControlCommand(command),
                "Expected \(command) to remain supported"
            )
        }
        XCTAssertFalse(AonsokuNativeAudioPlugin.isSupportedRemoteControlCommand(""))
        XCTAssertFalse(
            AonsokuNativeAudioPlugin.isSupportedRemoteControlCommand("unsupported")
        )
    }

    func testRemoteCommandPayloadKeepsSelectedSongIdsAndPositions() {
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeRemoteControlCommand([
                "type": "add_to_queue_next",
                "song_ids": ["a", "b"],
            ]),
            .addToQueue(songIds: ["a", "b"], position: "next")
        )
        XCTAssertEqual(
            AonsokuNativeAudioPlugin.decodeRemoteControlCommand([
                "type": "reorder_queue",
                "from": 3,
                "to": 1,
            ]),
            .reorderQueue(from: 3, to: 1)
        )
    }
}
