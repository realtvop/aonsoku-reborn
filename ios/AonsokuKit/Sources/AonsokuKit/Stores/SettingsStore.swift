import Foundation
import Perception

/// App settings, persisted as JSON under `settings.v1` in the native
/// preferences. Unknown or missing fields decode to their defaults.
@MainActor
@Perceptible
public final class SettingsStore {
    public private(set) var settings = AppSettings()

    @PerceptionIgnored public let preferences: PreferencesService
    @PerceptionIgnored private var handlers: [@MainActor (AppSettings, AppSettings) -> Void] = []

    nonisolated public static let storageKey = "settings.v1"

    public init(preferences: PreferencesService) {
        self.preferences = preferences
    }

    /// Reads the stored settings. Call once at start, after migration.
    public func load() {
        settings = preferences.getJSON(Self.storageKey, as: AppSettings.self) ?? AppSettings()
    }

    /// Changes settings, saves them and notifies `onChange` handlers when
    /// something changed.
    public func update(_ body: (inout AppSettings) -> Void) {
        var next = settings
        body(&next)
        guard next != settings else { return }
        let previous = settings
        settings = next
        persist()
        for handler in handlers {
            handler(previous, next)
        }
    }

    /// Restores every default, keeping only the language.
    public func reset() {
        update { settings in
            let language = settings.languageCode
            settings = AppSettings()
            settings.languageCode = language
        }
    }

    /// Calls `handler` with the old and new settings after every change.
    public func onChange(_ handler: @escaping @MainActor (AppSettings, AppSettings) -> Void) {
        handlers.append(handler)
    }

    private func persist() {
        try? preferences.setJSON(settings, for: Self.storageKey)
    }
}
