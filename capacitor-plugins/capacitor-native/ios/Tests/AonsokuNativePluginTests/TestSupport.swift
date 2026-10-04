import Foundation
@testable import AonsokuNativePlugin

func makeSong(_ id: String, duration: Double = 180) -> QueueSong {
    QueueSong(
        id: id,
        title: "Song \(id)",
        artist: "Artist",
        album: "Album",
        duration: duration,
        streamUrl: "https://example.test/stream/\(id)"
    )
}

func makeSongRecord(_ id: String, title: String? = nil) -> SongRecord {
    SongRecord(
        id: id,
        parent: "album-1",
        title: title ?? "Song \(id)",
        album: "Album",
        artist: "Artist",
        track: nil,
        year: nil,
        genre: nil,
        coverArt: nil,
        size: nil,
        contentType: "audio/mpeg",
        suffix: "mp3",
        duration: 180,
        bitRate: nil,
        path: nil,
        playCount: nil,
        discNumber: nil,
        created: nil,
        albumId: "album-1",
        artistId: "artist-1",
        played: nil,
        starred: nil,
        starredAt: nil,
        playedAt: nil,
        bpm: nil,
        comment: nil,
        sortName: nil,
        mediaType: "song",
        musicBrainzId: nil,
        genresJson: nil,
        replayGainJson: nil
    )
}

func makeSilentWAVData() -> Data {
    let samples = Data(repeating: 0, count: 800)
    let dataSize = UInt32(samples.count)
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.appendLittleEndian(36 + dataSize)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(8_000))
    data.appendLittleEndian(UInt32(16_000))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    data.appendLittleEndian(dataSize)
    data.append(samples)
    return data
}

final class TemporaryDatabase {
    let directory: URL
    let manager: DatabaseManager

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aonsoku-ios-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        manager = try DatabaseManager(
            path: directory.appendingPathComponent("library.sqlite").path
        )
    }

    deinit {
        try? manager.dbPool.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
