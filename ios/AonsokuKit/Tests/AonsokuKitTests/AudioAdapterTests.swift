import XCTest
@testable import AonsokuKit

final class AudioAdapterTests: XCTestCase {
    func testSourcePayloadsPreserveEverySupportedKind() {
        XCTAssertEqual(
            AudioPayloadCodec.decodeSource([
                "kind": "stream",
                "url": "https://example.test/song.mp3",
                "songId": "song-1",
            ]),
            .stream(url: "https://example.test/song.mp3", songId: "song-1")
        )
        XCTAssertEqual(
            AudioPayloadCodec.decodeSource([
                "kind": "native-file",
                "uri": "file:///tmp/song.flac",
                "songId": "song-2",
            ]),
            .nativeFile(uri: "file:///tmp/song.flac", songId: "song-2")
        )
        XCTAssertEqual(
            AudioPayloadCodec.decodeSource([
                "kind": "radio",
                "url": "https://radio.example.test/live",
                "radioId": "radio-1",
            ]),
            .radio(url: "https://radio.example.test/live", radioId: "radio-1")
        )
        XCTAssertEqual(
            AudioPayloadCodec.decodeSource([
                "kind": "blob",
                "url": "blob:https://example.test/id",
                "songId": "song-3",
            ]),
            .blob(url: "blob:https://example.test/id", songId: "song-3")
        )
    }

    func testSourcePayloadRejectsMissingAndUnknownKinds() {
        XCTAssertNil(AudioPayloadCodec.decodeSource(nil))
        XCTAssertNil(AudioPayloadCodec.decodeSource(["kind": "stream"]))
        XCTAssertNil(AudioPayloadCodec.decodeSource([
            "kind": "unsupported",
            "url": "https://example.test",
        ]))
    }

    func testMetadataPayloadPreservesContractFieldsAndNumericTypes() {
        let metadata = AudioPayloadCodec.decodeMetadata([
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
            AudioPayloadCodec.decodeMetadata(nil),
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
                AudioPayloadCodec.isSupportedRemoteControlCommand(command),
                "Expected \(command) to remain supported"
            )
        }
        XCTAssertFalse(AudioPayloadCodec.isSupportedRemoteControlCommand(""))
        XCTAssertFalse(
            AudioPayloadCodec.isSupportedRemoteControlCommand("unsupported")
        )
    }

    func testRemoteCommandPayloadKeepsSelectedSongIdsAndPositions() {
        XCTAssertEqual(
            AudioPayloadCodec.decodeRemoteControlCommand([
                "type": "add_to_queue_next",
                "song_ids": ["a", "b"],
            ]),
            .addToQueue(songIds: ["a", "b"], position: "next")
        )
        XCTAssertEqual(
            AudioPayloadCodec.decodeRemoteControlCommand([
                "type": "reorder_queue",
                "from": 3,
                "to": 1,
            ]),
            .reorderQueue(from: 3, to: 1)
        )
    }

    func testRemoteCommandPayloadValidatesNumericRangesAndTypes() {
        XCTAssertEqual(
            AudioPayloadCodec.decodeRemoteControlCommand([
                "type": "seek", "seconds": 12.5,
            ]),
            .seek(12.5)
        )
        XCTAssertEqual(
            AudioPayloadCodec.decodeRemoteControlCommand([
                "type": "set_volume", "volume": 1,
            ]),
            .setVolume(1)
        )

        let invalidCommands: [[String: Any]] = [
            ["type": "seek"],
            ["type": "seek", "seconds": -1],
            ["type": "seek", "seconds": Double.infinity],
            ["type": "set_volume"],
            ["type": "set_volume", "volume": 1.1],
            ["type": "set_volume", "volume": Double.nan],
            ["type": "set_shuffle", "enabled": "true"],
            ["type": "set_repeat", "mode": "track"],
            ["type": "reorder_queue", "from": -1, "to": 0],
            ["type": "reorder_queue", "from": 0.5, "to": 1],
            [
                "type": "reorder_queue",
                "from": 9_223_372_036_854_775_808.0,
                "to": 0,
            ],
        ]
        for command in invalidCommands {
            XCTAssertNil(
                AudioPayloadCodec.decodeRemoteControlCommand(command),
                "Expected invalid command to be rejected: \(command)"
            )
        }
    }

    func testRemoteCommandPayloadValidatesIdsListsAndIndexes() {
        XCTAssertEqual(
            AudioPayloadCodec.decodeRemoteControlCommand([
                "type": "play_album", "album_id": "album-1",
            ]),
            .playAlbum(id: "album-1", index: 0, shuffle: false)
        )
        XCTAssertEqual(
            AudioPayloadCodec.decodeRemoteControlCommand([
                "type": "play_at_index",
                "song_ids": ["a", "b"],
                "index": 1,
            ]),
            .playAtIndex(songIds: ["a", "b"], index: 1)
        )

        let invalidCommands: [[String: Any]] = [
            ["type": "play_song", "song_id": ""],
            ["type": "play_album", "album_id": "album-1", "index": "0"],
            ["type": "play_playlist", "playlist_id": "playlist-1", "shuffle": 1],
            ["type": "add_to_queue_next"],
            ["type": "add_to_queue_last", "song_ids": ["a", 2]],
            ["type": "remove_from_queue", "song_ids": [""]],
            ["type": "play_at_index", "song_ids": ["a"], "index": 1],
            ["type": "play_at_index", "song_ids": [], "index": 0],
        ]
        for command in invalidCommands {
            XCTAssertNil(
                AudioPayloadCodec.decodeRemoteControlCommand(command),
                "Expected invalid command to be rejected: \(command)"
            )
        }
    }
}
