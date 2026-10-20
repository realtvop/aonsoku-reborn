import Foundation
import Observation

/// Translations shared with the web app. Strings come from the i18next
/// files in `src/i18n/locales`, copied into the app bundle as
/// `locales/<resourceName>.json`; `native-locales/<resourceName>.json`
/// overlays native-only strings when present. Missing keys fall back to
/// English, then to the key itself.
@MainActor
@Observable
public final class Localizer {
    /// The active language.
    public private(set) var language: AppLanguage
    /// The user's choice, or nil to follow the system languages.
    public private(set) var selectedCode: String?

    @ObservationIgnored public let bundle: Bundle
    @ObservationIgnored public let preferredLanguages: [String]

    public init(bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.bundle = bundle
        self.preferredLanguages = preferredLanguages
        self.language = AppLanguage.language(code: AppLanguage.fallbackCode) ?? AppLanguage.all[0]
    }

    public var locale: Locale { Locale(identifier: language.code) }

    /// Switches language; nil follows the system languages.
    public func setLanguage(code: String?) {}

    /// The string for a dotted key such as `settings.tabs.general`, with
    /// `{{name}}` placeholders replaced from `args`.
    public func t(_ key: String, _ args: [String: String] = [:]) -> String { key }

    /// Plural form: looks up `<key>_one` or `<key>_other` (and the other
    /// CLDR categories for the language) and fills `{{count}}`.
    public func t(_ key: String, count: Int, _ args: [String: String] = [:]) -> String { key }

    /// True when the key exists in the active language or English.
    public func has(_ key: String) -> Bool { false }
}
