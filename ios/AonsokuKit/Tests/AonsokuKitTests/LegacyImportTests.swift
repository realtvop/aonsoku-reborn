import XCTest
@testable import AonsokuKit

@MainActor
final class LegacyImportTests: XCTestCase {
    func testMapsCacheLyricsAndCustomBodies() throws {
        let payload: [String: Any] = [
            "cacheMeta": [
                [
                    "key": "audio:keep",
                    "id": "keep",
                    "type": "audio",
                    "source": "smart",
                    "triggers": ["favorite"],
                    "sizeBytes": 12,
                    "cachedAt": 100,
                    "lastAccessedAt": 200,
                ],
                [
                    "key": "audio:missing",
                    "id": "missing",
                    "type": "audio",
                    "source": "explicit",
                    "sizeBytes": 20,
                    "cachedAt": 100,
                    "lastAccessedAt": 100,
                ],
            ],
            "lyrics": [
                ["songId": "keep", "content": "[00:01]Line", "synced": true],
            ],
            "cacheStore": [
                [
                    "key": "cache-index-v1",
                    "value": [
                        "album:a": [
                            "id": "a",
                            "type": "album",
                            "sizeBytes": 0,
                            "cachedAt": 300,
                            "lastAccessedAt": 300,
                        ],
                    ],
                ],
            ],
            "customLyrics": [
                ["key": "custom-lyrics:song-key", "value": "Custom"],
                ["key": "custom-lyrics-romaji:song-key", "value": "Romaji"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let mapped = try LegacyWebDataImporter.map(
            json: String(decoding: data, as: UTF8.self),
            nativeFileExists: { type, id in type != .audio || id == "keep" },
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(mapped.cacheRows.map(\.key), ["album:a", "audio:keep"])
        XCTAssertEqual(mapped.cacheRows.last?.source, "smart")
        XCTAssertEqual(mapped.cacheRows.last?.triggersJson, "[\"favorite\"]")
        XCTAssertEqual(mapped.lyrics.first?.songId, "keep")
        XCTAssertEqual(mapped.customLyrics["song-key"]?.lyrics, "Custom")
        XCTAssertEqual(mapped.customLyrics["song-key"]?.romaji, "Romaji")
    }

    func testSuccessfulEmptyImportMarksDoneAndFailureRetries() async throws {
        let database = try TemporaryDatabase()
        let library = LibraryService(
            dbManager: database.manager,
            credentialsProvider: { nil }
        )
        let preferences = PreferencesService(db: database.manager.dbPool)
        let successful = LegacyWebDataImporter(
            library: library,
            preferences: preferences,
            reader: { "{\"cacheMeta\":[],\"lyrics\":[],\"customLyrics\":[]}" }
        )
        XCTAssertTrue(successful.isNeeded)
        let successfulReport = await successful.run()
        XCTAssertEqual(successfulReport, LegacyImportReport())
        XCTAssertFalse(successful.isNeeded)

        preferences.remove(LegacyWebDataImporter.doneKey)
        let failed = LegacyWebDataImporter(
            library: library,
            preferences: preferences,
            reader: { throw ImportTestError.readFailed }
        )
        let failedReport = await failed.run()
        XCTAssertEqual(failedReport, LegacyImportReport(failed: true))
        XCTAssertTrue(failed.isNeeded)
    }
}

private enum ImportTestError: Error {
    case readFailed
}
