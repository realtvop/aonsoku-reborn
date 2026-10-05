import GRDB
import XCTest
@testable import AonsokuNativePlugin

final class LegacyQueueMigrationTests: XCTestCase {
    func testRestoresQueueStatePersistedByTheLegacyPreferencesPlugin() throws {
        let database = try TemporaryDatabase()
        let song: [String: Any] = [
            "id": "legacy-song",
            "title": "Legacy song",
            "artist": "Legacy artist",
            "album": "Legacy album",
            "duration": 214.0,
            "coverArt": "legacy-cover",
        ]
        let legacyState: [String: Any] = [
            "contextQueue": [
                "songs": [song],
                "currentIndex": 0,
                "sourceId": ["type": "album", "id": "legacy-album"],
                "sourceName": "Legacy album",
            ],
            "userQueue": ["songs": [[
                "id": "queued-song",
                "title": "Queued song",
                "artist": "Legacy artist",
                "album": "Legacy album",
                "duration": 90.0,
            ]]],
            "originalContextSongs": [song],
            "originalUserSongs": [],
            "playedUserQueueHistory": [],
            "isShuffleActive": true,
            "isInUserQueue": false,
            "shuffleHistory": ["legacy-song"],
            "shuffleStartHistory": ["legacy-song"],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: legacyState)
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        try database.manager.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO queueState (key, stateJson, updatedAt)
                    VALUES ('current', ?, ?)
                    """,
                arguments: [json, Int(Date().timeIntervalSince1970 * 1000)]
            )
        }

        let service = AudioService(databaseManager: database.manager)
        let started = expectation(description: "service restored legacy queue")
        service.start()
        DispatchQueue.main.async { started.fulfill() }
        wait(for: [started], timeout: 2)

        let restored = try XCTUnwrap(service.fullState())
        XCTAssertEqual(restored.contextSongs.map(\.id), ["legacy-song"])
        XCTAssertEqual(restored.contextSongs.first?.coverArtId, "legacy-cover")
        XCTAssertEqual(restored.userQueue.map(\.id), ["queued-song"])
        XCTAssertEqual(restored.sourceId, AudioQueueSource(type: "album", id: "legacy-album"))
        XCTAssertEqual(restored.sourceName, "Legacy album")
        XCTAssertTrue(restored.isShuffleActive)

        let migrated = try XCTUnwrap(
            PlaybackStateRepository(db: database.manager.dbPool).load()
        )
        XCTAssertEqual(migrated.contextSongs.map(\.id), ["legacy-song"])
        let legacyRow = try database.manager.dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT stateJson FROM queueState WHERE key = 'current'"
            )
        }
        XCTAssertNil(legacyRow)
        service.shutdown()
    }
}
