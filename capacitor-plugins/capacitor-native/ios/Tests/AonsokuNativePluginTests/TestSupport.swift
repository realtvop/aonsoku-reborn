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
