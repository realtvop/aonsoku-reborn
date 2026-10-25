import Foundation

/// Moves the Capacitor app's zustand stores, kept as `{state, version}` JSON
/// in the native preferences table, into the native stores. Runs once;
/// later launches return immediately.
///
/// - `theme_store`, `lang_store`, `app_store`, `player_store` and the cache
///   settings store become `AppSettings` under `SettingsStore.storageKey`.
/// - `pinned_home_store` becomes `PinnedHomeStore` items under `pinned.v1`.
/// - `player_history` songs move into the native play history.
/// - Lyrics selections move to `lyrics.selections.v1`.
///
/// Legacy keys are left in place so a failed run can be repeated.
public struct SettingsMigration: Sendable {
    public static let doneKey = "settings.migrated.v1"

    public let preferences: PreferencesService

    public init(preferences: PreferencesService) {
        self.preferences = preferences
    }

    /// Imports legacy settings when it has not happened yet.
    public func run() {
        guard preferences.getString(Self.doneKey) == nil else { return }

        var settings = preferences.getJSON(
            SettingsStore.storageKey,
            as: AppSettings.self
        ) ?? AppSettings()
        if preferences.getString(SettingsStore.storageKey) == nil {
            migrateSettings(into: &settings)
            do {
                try preferences.setJSON(settings, for: SettingsStore.storageKey)
            } catch {
                return
            }
        }

        guard migratePins(), migrateHistory(maxSize: settings.history.maxSize),
              migrateLyricsSelections() else {
            return
        }
        preferences.setString("true", for: Self.doneKey)
    }

    private func migrateSettings(into settings: inout AppSettings) {
        if let theme = legacyState("theme_store") {
            if let raw = string(theme, ["themeMode"]), let value = ThemeMode(rawValue: raw) {
                settings.appearance.themeMode = value
            }
            if let raw = string(theme, ["lightTheme"]), let value = AppTheme(rawValue: raw) {
                settings.appearance.lightTheme = value
            }
            if let raw = string(theme, ["darkTheme"]), let value = AppTheme(rawValue: raw) {
                settings.appearance.darkTheme = value
            }
        }

        if let language = legacyState("lang_store"),
           let code = string(language, ["langCode"]),
           !code.isEmpty,
           let matched = Self.languageCode(for: code) {
            settings.languageCode = matched
        }

        if let app = legacyState("app_store"),
           let value = bool(app, ["pages", "hideRadiosSection"]) {
            settings.content.hideRadiosSection = value
        }

        if let player = legacyState("player_store") {
            if let value = bool(player, ["settings", "fullscreen", "autoFullscreenEnabled"]) {
                settings.playback.autoOpenNowPlaying = value
            }
            if let value = bool(player, ["settings", "coverArt", "useAlbumCoverForSongs"]) {
                settings.playback.useAlbumCoverForSongs = value
            }
            if let value = bool(player, ["settings", "hapticFeedback", "hapticFeedbackEnabled"]) {
                settings.playback.hapticFeedback = value
            }
            if let value = bool(player, ["settings", "privacy", "lrcLibEnabled"]) {
                settings.privacy.lrcLibEnabled = value
            }
            if let value = double(player, ["settings", "colors", "currentSongColorIntensity"]) {
                settings.appearance.nowPlayingColorIntensity = value.clamped(
                    to: AppearanceSettings.colorIntensityRange
                )
            }

            if let value = bool(player, ["settings", "replayGain", "values", "enabled"]) {
                settings.replayGain.enabled = value
            }
            if let raw = string(player, ["settings", "replayGain", "values", "type"]),
               let value = ReplayGainMode(rawValue: raw) {
                settings.replayGain.mode = value
            }
            if let value = double(player, ["settings", "replayGain", "values", "preAmp"]) {
                settings.replayGain.preAmp = value.clamped(to: ReplayGainSettings.preAmpRange)
            }
            if let value = double(player, ["settings", "replayGain", "values", "defaultGain"]) {
                settings.replayGain.defaultGain = value.clamped(
                    to: ReplayGainSettings.defaultGainRange
                )
            }

            if let value = bool(player, ["settings", "lyrics", "preferSyncedLyrics"]) {
                settings.lyrics.preferSyncedLyrics = value
            }
            if let value = bool(player, ["settings", "lyrics", "showTranslation"]) {
                settings.lyrics.showTranslation = value
            }
            if let raw = array(player, ["settings", "lyrics", "sourcePriority"]) as? [String] {
                let values = raw.compactMap(LyricsSource.init(rawValue:))
                if !values.isEmpty {
                    settings.lyrics.sourcePriority = LyricsSettings.normalizedPriority(values)
                }
            }
            if let value = bool(player, ["settings", "lyrics", "customServerEnabled"]) {
                settings.lyrics.customServerEnabled = value
            }
            if let value = string(player, ["settings", "lyrics", "customServerUrl"]) {
                settings.lyrics.customServerUrl = value
            }
            if let value = string(player, ["settings", "lyrics", "customServerPassword"]) {
                settings.lyrics.customServerPassword = Self.decodedPassword(value)
            }
        }

        if let cache = legacyState("cache_settings") {
            if let value = int64(cache, ["settings", "assetsQuota"]), value >= 0 {
                settings.cache.assetsQuota = value
            }
            if let value = int64(cache, ["settings", "lruQuota"]), value >= 0 {
                settings.cache.lruQuota = value
            }
            if let value = bool(cache, ["settings", "smartRules", "enabled"]) {
                settings.cache.smartRules.enabled = value
            }
            if let value = bool(cache, ["settings", "smartRules", "favoriteSongs"]) {
                settings.cache.smartRules.favoriteSongs = value
            }
            if let value = bool(cache, ["settings", "smartRules", "favoritePlaylists"]) {
                settings.cache.smartRules.favoritePlaylists = value
            }
            if let value = bool(cache, ["settings", "syncCoverArt"]) {
                settings.cache.syncCoverArt = value
            }
            if let value = int(cache, ["settings", "coverArtConcurrency"]) {
                settings.cache.coverArtConcurrency = min(
                    max(value, CacheSettings.coverArtConcurrencyRange.lowerBound),
                    CacheSettings.coverArtConcurrencyRange.upperBound
                )
            }
        }

        if let history = legacyState("player_history"),
           let value = int(history, ["maxSize"]) {
            settings.history.maxSize = min(
                max(value, HistorySettings.range.lowerBound),
                HistorySettings.range.upperBound
            )
        }
    }

    private func migratePins() -> Bool {
        guard preferences.getString("pinned.v1") == nil else { return true }
        guard let state = legacyState("pinned_home_store"),
              let items = array(state, ["items"]) else {
            return true
        }
        var seen = Set<String>()
        let pins = items.compactMap { value -> PinnedItem? in
            guard let item = value as? [String: Any],
                  let id = item["id"] as? String,
                  let rawKind = item["type"] as? String,
                  let kind = PinnedItem.Kind(rawValue: rawKind) else {
                return nil
            }
            let pin = PinnedItem(itemId: id, kind: kind)
            return seen.insert(pin.id).inserted ? pin : nil
        }
        do {
            try preferences.setJSON(pins, for: "pinned.v1")
            return true
        } catch {
            return false
        }
    }

    private func migrateHistory(maxSize: Int) -> Bool {
        guard (try? preferences.getPlayHistory(limit: 1))?.isEmpty == true else {
            return true
        }
        guard let state = legacyState("player_history"),
              let history = array(state, ["history"]) else {
            return true
        }
        do {
            for song in history.reversed() {
                let songJSON: String
                if let song = song as? String {
                    songJSON = song
                } else {
                    let data = try JSONSerialization.data(withJSONObject: song)
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    songJSON = value
                }
                try preferences.addToPlayHistory(songJSON: songJSON, maxSize: maxSize)
            }
            return true
        } catch {
            return false
        }
    }

    private func migrateLyricsSelections() -> Bool {
        guard preferences.getString("lyrics.selections.v1") == nil else { return true }
        guard let player = legacyState("player_store"),
              let selections = value(
                player,
                ["settings", "lyrics", "selectedCustomLyrics"]
              ) as? [String: Any] else {
            return true
        }
        guard JSONSerialization.isValidJSONObject(selections),
              let data = try? JSONSerialization.data(withJSONObject: selections),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        preferences.setString(json, for: "lyrics.selections.v1")
        return true
    }

    private func legacyState(_ key: String) -> [String: Any]? {
        guard let raw = preferences.getString(key),
              let root = Self.jsonObject(raw) as? [String: Any] else {
            return nil
        }
        return (root["state"] as? [String: Any]) ?? root
    }

    private static func jsonObject(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let nested = object as? String { return jsonObject(nested) }
        return object
    }

    private func value(_ root: [String: Any], _ path: [String]) -> Any? {
        path.reduce(root as Any?) { current, component in
            (current as? [String: Any])?[component]
        }
    }

    private func string(_ root: [String: Any], _ path: [String]) -> String? {
        value(root, path) as? String
    }

    private func bool(_ root: [String: Any], _ path: [String]) -> Bool? {
        value(root, path) as? Bool
    }

    private func array(_ root: [String: Any], _ path: [String]) -> [Any]? {
        value(root, path) as? [Any]
    }

    private func double(_ root: [String: Any], _ path: [String]) -> Double? {
        (value(root, path) as? NSNumber)?.doubleValue
    }

    private func int(_ root: [String: Any], _ path: [String]) -> Int? {
        (value(root, path) as? NSNumber)?.intValue
    }

    private func int64(_ root: [String: Any], _ path: [String]) -> Int64? {
        (value(root, path) as? NSNumber)?.int64Value
    }

    private static func languageCode(for code: String) -> String? {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if let exact = AppLanguage.all.first(where: {
            $0.code.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact.code
        }
        let lower = normalized.lowercased()
        switch lower.split(separator: "-").first {
        case "en": return "en-US"
        case "es": return "es-ES"
        case "fr": return lower.contains("-ca") ? "fr-CA" : "fr"
        case "pt": return lower.contains("-br") ? "pt-BR" : "pt"
        case "zh": return "zh-Hans"
        default:
            return AppLanguage.all.first {
                $0.code.lowercased().split(separator: "-").first
                    == lower.split(separator: "-").first
            }?.code
        }
    }

    private static func decodedPassword(_ value: String) -> String {
        guard value.hasPrefix("enc:") else { return value }
        let hex = value.dropFirst(4)
        guard hex.count.isMultiple(of: 2) else { return value }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return value }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? value
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
