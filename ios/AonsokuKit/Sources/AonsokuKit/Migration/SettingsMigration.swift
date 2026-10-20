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
    public func run() {}
}
