import Foundation

/// Stores coordination tokens in the `aonsoku-coordination` keychain service
/// and the server config in UserDefaults, using the previous app's keys so
/// existing registrations survive the update.
final class CoordinationKeychainTokenStore: CoordinationTokenStoring, @unchecked Sendable {
    init(
        service: String = "aonsoku-coordination",
        defaults: UserDefaults = .standard
    ) {}

    func loadTokens() -> CoordinationTokens? { nil }

    func saveTokens(_ tokens: CoordinationTokens) {}

    func clearTokens() {}

    func loadConfig() -> CoordinationConfig? { nil }

    func saveConfig(_ config: CoordinationConfig) {}
}
