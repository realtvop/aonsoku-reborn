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
}
