import XCTest
@testable import AonsokuKit

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testLoadUsesDefaultsForMissingOrCorruptSettings() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let store = SettingsStore(preferences: preferences)

        store.load()
        XCTAssertEqual(store.settings, AppSettings())

        preferences.setString("not json", for: SettingsStore.storageKey)
        store.load()
        XCTAssertEqual(store.settings, AppSettings())
    }

    func testUpdatePersistsAndNotifiesButLoadDoesNotNotify() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let store = SettingsStore(preferences: preferences)
        var changes: [(AppSettings, AppSettings)] = []
        store.onChange { changes.append(($0, $1)) }

        store.load()
        XCTAssertTrue(changes.isEmpty)
        store.update {
            $0.appearance.themeMode = .dark
            $0.cache.coverArtConcurrency = 7
        }
        store.update { $0.appearance.themeMode = .dark }

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].0.appearance.themeMode, .system)
        XCTAssertEqual(changes[0].1.appearance.themeMode, .dark)
        let restored = SettingsStore(preferences: preferences)
        restored.load()
        XCTAssertEqual(restored.settings, store.settings)
    }

    func testResetKeepsLanguage() throws {
        let database = try TemporaryDatabase()
        let store = SettingsStore(
            preferences: PreferencesService(db: database.manager.dbPool)
        )
        store.update {
            $0.languageCode = "ja"
            $0.appearance.themeMode = .dark
        }

        store.reset()

        XCTAssertEqual(store.settings.languageCode, "ja")
        XCTAssertEqual(store.settings.appearance.themeMode, .system)
    }

    func testDownloadConcurrencyDefaultsValidationAndPersistence() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let store = SettingsStore(preferences: preferences)
        preferences.setString(#"{"cache":{"lruQuota":1234}}"#, for: SettingsStore.storageKey)
        store.load()
        XCTAssertEqual(store.settings.cache.lruQuota, 1234)
        XCTAssertEqual(store.settings.cache.downloadConcurrency, 2)
        XCTAssertEqual(preferences.audioDownloadConcurrency, 2)

        for limit in [1, 2, 4, 8] {
            store.update { $0.cache.downloadConcurrency = limit }
            let restored = SettingsStore(preferences: preferences)
            restored.load()
            XCTAssertEqual(restored.settings.cache.downloadConcurrency, limit)
            XCTAssertEqual(preferences.audioDownloadConcurrency, limit)
        }
        for invalid in [-1, 0, 3, 7, 9, 100] {
            preferences.setString(
                "{\"cache\":{\"downloadConcurrency\":\(invalid)}}",
                for: SettingsStore.storageKey
            )
            store.load()
            XCTAssertEqual(store.settings.cache.downloadConcurrency, 2)
        }
        store.update { $0.cache.downloadConcurrency = 8 }
        store.reset()
        XCTAssertEqual(store.settings.cache.downloadConcurrency, 2)
        XCTAssertEqual(preferences.audioDownloadConcurrency, 2)
    }
}
