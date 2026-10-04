import XCTest
@testable import AonsokuNativePlugin

final class PreferencesTests: XCTestCase {
    func testTypedPreferencesRoundTripThroughInjectedDatabase() throws {
        let database = try TemporaryDatabase()
        let fixedDate = Date(timeIntervalSince1970: 1_234)
        let manager = PreferencesManager(
            db: database.manager.dbPool,
            now: { fixedDate }
        )

        manager.setValues([
            "name": "Aonsoku",
            "enabled": "true",
            "count": "7",
            "ratio": "0.75",
            "store": "{\"state\":{\"audio\":{\"native\":true}}}",
        ])

        XCTAssertEqual(manager.getString("name"), "Aonsoku")
        XCTAssertEqual(manager.getBool("enabled"), true)
        XCTAssertEqual(manager.getInt("count"), 7)
        XCTAssertEqual(manager.getDouble("ratio"), 0.75)
        XCTAssertEqual(
            manager.getNestedBool(store: "store", path: ["audio", "native"]),
            true
        )
        manager.waitForPendingWrites()

        let restored = PreferencesManager(db: database.manager.dbPool)
        XCTAssertEqual(restored.getAll()["name"], "Aonsoku")
        XCTAssertEqual(restored.getBool("enabled"), true)
    }

    func testDeleteUpdatesCacheAndPersistentStore() throws {
        let database = try TemporaryDatabase()
        let manager = PreferencesManager(db: database.manager.dbPool)
        manager.setValue("remove", value: "me")
        manager.waitForPendingWrites()

        manager.deleteValue("remove")
        XCTAssertNil(manager.getString("remove"))
        manager.waitForPendingWrites()

        XCTAssertNil(
            PreferencesManager(db: database.manager.dbPool).getString("remove")
        )
    }

    func testPlayHistoryPersistsNewestFirstTrimsAndZeroClears() throws {
        let database = try TemporaryDatabase()
        var timestamp = 100
        let store = PlayHistoryStore(
            db: database.manager.dbPool,
            now: {
                defer { timestamp += 1 }
                return timestamp
            }
        )

        try store.add(songJSON: "song-1", maxSize: 2)
        try store.add(songJSON: "song-2", maxSize: 2)
        try store.add(songJSON: "song-3", maxSize: 2)

        XCTAssertEqual(
            try PlayHistoryStore(db: database.manager.dbPool).history(limit: 10),
            ["song-3", "song-2"]
        )
        XCTAssertEqual(try store.history(limit: 1), ["song-3"])
        XCTAssertEqual(try store.history(limit: 0), [])

        try store.add(songJSON: "song-4", maxSize: 0)
        XCTAssertEqual(try store.history(limit: 10), [])
    }
}
