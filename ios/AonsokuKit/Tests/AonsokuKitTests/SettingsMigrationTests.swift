import XCTest
@testable import AonsokuKit

final class SettingsMigrationTests: XCTestCase {
    func testMigratesEveryLegacyStoreAndIsIdempotent() throws {
        let database = try TemporaryDatabase()
        var historyClock = 100
        let preferences = PreferencesService(
            db: database.manager.dbPool,
            historyNow: {
                defer { historyClock += 1 }
                return historyClock
            }
        )
        preferences.setValues([
            "theme_store": jsonStore([
                "themeMode": "dark",
                "lightTheme": "night-owl-light",
                "darkTheme": "dracula",
            ]),
            "lang_store": jsonStore(["langCode": "pt_BR"]),
            "app_store": jsonStore(["pages": ["hideRadiosSection": false]]),
            "player_store": jsonStore([
                "settings": [
                    "fullscreen": ["autoFullscreenEnabled": true],
                    "coverArt": ["useAlbumCoverForSongs": true],
                    "hapticFeedback": ["hapticFeedbackEnabled": false],
                    "privacy": ["lrcLibEnabled": false],
                    "colors": ["currentSongColorIntensity": 3.0],
                    "replayGain": [
                        "values": [
                            "enabled": true,
                            "type": "album",
                            "preAmp": -30.0,
                            "defaultGain": 5.0,
                        ],
                    ],
                    "lyrics": [
                        "preferSyncedLyrics": true,
                        "showTranslation": false,
                        "sourcePriority": ["custom", "navidrome", "custom"],
                        "customServerEnabled": true,
                        "customServerUrl": "https://lyrics.test",
                        "customServerPassword": "enc:736563726574",
                        "selectedCustomLyrics": [
                            "song-key": ["key": "candidate", "id": "server-id", "offset": 0.4],
                        ],
                    ],
                ],
            ]),
            "cache_settings": jsonStore([
                "settings": [
                    "assetsQuota": 123,
                    "lruQuota": 456,
                    "smartRules": [
                        "enabled": true,
                        "favoriteSongs": false,
                        "favoritePlaylists": true,
                    ],
                    "syncCoverArt": true,
                    "coverArtConcurrency": 99,
                ],
            ]),
            "pinned_home_store": jsonStore([
                "items": [
                    ["id": "album-1", "type": "album"],
                    ["id": "playlist-1", "type": "playlist"],
                    ["id": "album-1", "type": "album"],
                ],
            ]),
            "player_history": jsonStore([
                "history": [
                    ["id": "new", "title": "Newest"],
                    ["id": "old", "title": "Oldest"],
                ],
                "maxSize": 5_000,
            ]),
        ])

        SettingsMigration(preferences: preferences).run()

        let settings = try XCTUnwrap(
            preferences.getJSON(SettingsStore.storageKey, as: AppSettings.self)
        )
        XCTAssertEqual(settings.appearance.themeMode, .dark)
        XCTAssertEqual(settings.appearance.lightTheme, .nightOwlLight)
        XCTAssertEqual(settings.appearance.darkTheme, .dracula)
        XCTAssertEqual(settings.appearance.nowPlayingColorIntensity, 1)
        XCTAssertEqual(settings.languageCode, "pt-BR")
        XCTAssertTrue(settings.playback.autoOpenNowPlaying)
        XCTAssertTrue(settings.playback.useAlbumCoverForSongs)
        XCTAssertFalse(settings.playback.hapticFeedback)
        XCTAssertFalse(settings.content.hideRadiosSection)
        XCTAssertFalse(settings.privacy.lrcLibEnabled)
        XCTAssertTrue(settings.replayGain.enabled)
        XCTAssertEqual(settings.replayGain.mode, .album)
        XCTAssertEqual(settings.replayGain.preAmp, -15)
        XCTAssertEqual(settings.replayGain.defaultGain, -1)
        XCTAssertTrue(settings.lyrics.preferSyncedLyrics)
        XCTAssertFalse(settings.lyrics.showTranslation)
        XCTAssertEqual(settings.lyrics.sourcePriority, [.custom, .navidrome, .lrclib])
        XCTAssertTrue(settings.lyrics.customServerEnabled)
        XCTAssertEqual(settings.lyrics.customServerUrl, "https://lyrics.test")
        XCTAssertEqual(settings.lyrics.customServerPassword, "secret")
        XCTAssertEqual(settings.cache.assetsQuota, 123)
        XCTAssertEqual(settings.cache.lruQuota, 456)
        XCTAssertTrue(settings.cache.smartRules.enabled)
        XCTAssertFalse(settings.cache.smartRules.favoriteSongs)
        XCTAssertTrue(settings.cache.smartRules.favoritePlaylists)
        XCTAssertTrue(settings.cache.syncCoverArt)
        XCTAssertEqual(settings.cache.coverArtConcurrency, 8)
        XCTAssertEqual(settings.history.maxSize, 1_000)

        XCTAssertEqual(
            preferences.getJSON("pinned.v1", as: [PinnedItem].self),
            [
                PinnedItem(itemId: "album-1", kind: .album),
                PinnedItem(itemId: "playlist-1", kind: .playlist),
            ]
        )
        let history = try preferences.getPlayHistory(limit: 10)
        XCTAssertTrue(history[0].contains("new"))
        XCTAssertTrue(history[1].contains("old"))
        let selections = try jsonDictionary(
            XCTUnwrap(preferences.getString("lyrics.selections.v1"))
        )
        XCTAssertEqual(
            ((selections["song-key"] as? [String: Any])?["key"] as? String),
            "candidate"
        )
        XCTAssertEqual(preferences.getString(SettingsMigration.doneKey), "true")

        preferences.setString(jsonStore(["langCode": "ja"]), for: "lang_store")
        SettingsMigration(preferences: preferences).run()
        XCTAssertEqual(
            preferences.getJSON(SettingsStore.storageKey, as: AppSettings.self)?.languageCode,
            "pt-BR"
        )
    }

    func testExistingNativeValuesAreLeftAlone() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        var settings = AppSettings()
        settings.languageCode = "ja"
        let pins = [PinnedItem(itemId: "native", kind: .album)]
        try preferences.setJSON(settings, for: SettingsStore.storageKey)
        try preferences.setJSON(pins, for: "pinned.v1")
        try preferences.addToPlayHistory(songJSON: "native-history")
        preferences.setString("{\"native\":{\"key\":\"value\"}}", for: "lyrics.selections.v1")
        preferences.setValues([
            "lang_store": jsonStore(["langCode": "fr"]),
            "pinned_home_store": jsonStore([
                "items": [["id": "legacy", "type": "playlist"]],
            ]),
            "player_history": jsonStore(["history": [["id": "legacy"]]]),
            "player_store": jsonStore([
                "settings": [
                    "lyrics": [
                        "selectedCustomLyrics": ["legacy": ["key": "legacy"]],
                    ],
                ],
            ]),
        ])

        SettingsMigration(preferences: preferences).run()

        XCTAssertEqual(
            preferences.getJSON(SettingsStore.storageKey, as: AppSettings.self)?.languageCode,
            "ja"
        )
        XCTAssertEqual(preferences.getJSON("pinned.v1", as: [PinnedItem].self), pins)
        XCTAssertEqual(try preferences.getPlayHistory(limit: 10), ["native-history"])
        XCTAssertEqual(
            preferences.getString("lyrics.selections.v1"),
            "{\"native\":{\"key\":\"value\"}}"
        )
        XCTAssertEqual(preferences.getString(SettingsMigration.doneKey), "true")
    }

    private func jsonStore(_ state: [String: Any]) -> String {
        json(["state": state, "version": 1])
    }

    private func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func jsonDictionary(_ value: String) throws -> [String: Any] {
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
