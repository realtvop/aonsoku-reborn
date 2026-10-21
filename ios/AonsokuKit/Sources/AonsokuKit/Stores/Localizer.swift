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
    @ObservationIgnored private var files: [String: [String: Any]] = [:]
    @ObservationIgnored private var missingFiles = Set<String>()

    public init(bundle: Bundle = .main, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.bundle = bundle
        self.preferredLanguages = preferredLanguages
        self.language = AppLanguage.language(code: AppLanguage.fallbackCode) ?? AppLanguage.all[0]
        setLanguage(code: nil)
    }

    public var locale: Locale { Locale(identifier: language.code) }

    /// Switches language; nil follows the system languages.
    public func setLanguage(code: String?) {
        if let code, let explicit = AppLanguage.language(code: code) {
            selectedCode = code
            language = explicit
            warmCache(for: explicit)
            return
        }
        selectedCode = nil
        language = preferredLanguages.lazy.compactMap(Self.matchLanguage).first
            ?? AppLanguage.language(code: AppLanguage.fallbackCode)
            ?? AppLanguage.all[0]
        warmCache(for: language)
    }

    /// The string for a dotted key such as `settings.tabs.general`, with
    /// `{{name}}` placeholders replaced from `args`.
    public func t(_ key: String, _ args: [String: String] = [:]) -> String {
        interpolate(rawString(key) ?? key, args: args)
    }

    /// Plural form: looks up `<key>_one` or `<key>_other` (and the other
    /// CLDR categories for the language) and fills `{{count}}`.
    public func t(_ key: String, count: Int, _ args: [String: String] = [:]) -> String {
        let resolved: String
        if count == 0, let zero = rawString("\(key)_zero") {
            resolved = zero
        } else {
            resolved = rawString("\(key)_\(pluralCategory(count))")
                ?? rawString("\(key)_other")
                ?? rawString(key)
                ?? key
        }
        var values = args
        values["count"] = String(count)
        return interpolate(resolved, args: values)
    }

    /// True when the key exists in the active language or English.
    public func has(_ key: String) -> Bool { rawString(key) != nil }

    private static func matchLanguage(_ requested: String) -> AppLanguage? {
        let normalized = requested.replacingOccurrences(of: "_", with: "-")
        if let exact = AppLanguage.all.first(where: {
            $0.code.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        let lower = normalized.lowercased()
        let pieces = lower.split(separator: "-")
        guard let base = pieces.first else { return nil }
        switch base {
        case "en": return AppLanguage.language(code: "en-US")
        case "es": return AppLanguage.language(code: "es-ES")
        case "fr":
            return AppLanguage.language(code: pieces.contains("ca") ? "fr-CA" : "fr")
        case "pt":
            return AppLanguage.language(code: pieces.contains("br") ? "pt-BR" : "pt")
        case "zh": return AppLanguage.language(code: "zh-Hans")
        default:
            return AppLanguage.all.first {
                $0.code.lowercased().split(separator: "-").first == base
            }
        }
    }

    private func warmCache(for language: AppLanguage) {
        _ = file(directory: "locales", name: language.resourceName)
        _ = file(directory: "native-locales", name: language.resourceName)
        _ = file(directory: "locales", name: "en")
        _ = file(directory: "native-locales", name: "en")
    }

    private func rawString(_ key: String) -> String? {
        let sources = [
            file(directory: "native-locales", name: language.resourceName),
            file(directory: "locales", name: language.resourceName),
            file(directory: "native-locales", name: "en"),
            file(directory: "locales", name: "en"),
        ]
        for source in sources {
            if let value = lookup(key, in: source) as? String { return value }
        }
        return nil
    }

    private func file(directory: String, name: String) -> [String: Any] {
        let cacheKey = "\(directory)/\(name)"
        if let cached = files[cacheKey] { return cached }
        guard !missingFiles.contains(cacheKey),
              let url = bundle.url(
                  forResource: name,
                  withExtension: "json",
                  subdirectory: directory
              ),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            missingFiles.insert(cacheKey)
            return [:]
        }
        files[cacheKey] = dictionary
        return dictionary
    }

    private func lookup(_ key: String, in root: [String: Any]) -> Any? {
        key.split(separator: ".").reduce(root as Any?) { current, component in
            (current as? [String: Any])?[String(component)]
        }
    }

    private func interpolate(_ source: String, args: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#
        ) else {
            return source
        }
        let mutable = NSMutableString(string: source)
        let range = NSRange(location: 0, length: mutable.length)
        for match in regex.matches(in: source, range: range).reversed() {
            guard match.numberOfRanges == 2,
                  let nameRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            let name = source[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if let replacement = args[name] {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }

    private func pluralCategory(_ count: Int) -> String {
        let number = abs(count)
        let mod10 = number % 10
        let mod100 = number % 100
        switch language.code {
        case "ja", "ko", "zh-Hans":
            return "other"
        case "fr", "fr-CA", "pt-BR":
            return number == 0 || number == 1 ? "one" : "other"
        case "cs":
            if number == 1 { return "one" }
            return (2...4).contains(number) ? "few" : "other"
        case "pl":
            if number == 1 { return "one" }
            if (2...4).contains(mod10), !(12...14).contains(mod100) { return "few" }
            return "many"
        case "ru", "uk":
            if mod10 == 1, mod100 != 11 { return "one" }
            if (2...4).contains(mod10), !(12...14).contains(mod100) { return "few" }
            return "many"
        default:
            return number == 1 ? "one" : "other"
        }
    }
}
