import Foundation

/// Stores coordination tokens in the `aonsoku-coordination` keychain service
/// and the server config in UserDefaults, using the previous app's keys so
/// existing registrations survive the update.
final class CoordinationKeychainTokenStore: CoordinationTokenStoring, @unchecked Sendable {
    private let service: String
    private let defaults: UserDefaults
    private let lock = NSLock()

    // For tests: injectable keychain and defaults access
    internal struct CoordinationKeychainAccess {
        var get: (String) -> String?
        var set: (String, String) -> Void
        var delete: (String) -> Void
    }

    private let keychainAccess: CoordinationKeychainAccess?

    init(
        service: String = "aonsoku-coordination",
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
        self.keychainAccess = nil
    }

    internal init(keychain: CoordinationKeychainAccess, defaults: UserDefaults) {
        self.service = "aonsoku-coordination"
        self.defaults = defaults
        self.keychainAccess = keychain
    }

    private func keychainGet(_ key: String) -> String? {
        if let access = keychainAccess {
            return access.get(key)
        }
        return KeychainManager.get(key, service: service)
    }

    private func keychainSet(_ key: String, _ value: String) {
        if let access = keychainAccess {
            access.set(key, value)
        } else {
            KeychainManager.set(value, forKey: key, service: service)
        }
    }

    private func keychainDelete(_ key: String) {
        if let access = keychainAccess {
            access.delete(key)
        } else {
            KeychainManager.delete(key, service: service)
        }
    }

    func loadTokens() -> CoordinationTokens? {
        lock.withLock { loadTokensLocked() }
    }

    private func loadTokensLocked() -> CoordinationTokens? {
        guard let accessToken = keychainGet("coord_access_token"),
              let refreshToken = keychainGet("coord_refresh_token"),
              let deviceId = keychainGet("coord_device_id"),
              let accountId = keychainGet("coord_account_id") else {
            return nil
        }

        let expiresAtStr = keychainGet("coord_access_token_expires_at") ?? "0"
        let historyLimitStr = keychainGet("coord_history_limit") ?? "100"

        let accessTokenExpiresAt = Double(expiresAtStr) ?? 0
        let historyLimit = Int(historyLimitStr) ?? 100

        return CoordinationTokens(
            deviceId: deviceId,
            accountId: accountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: accessTokenExpiresAt,
            historyLimit: historyLimit
        )
    }

    func saveTokens(_ tokens: CoordinationTokens) {
        lock.withLock { saveTokensLocked(tokens) }
    }

    private func saveTokensLocked(_ tokens: CoordinationTokens) {
        keychainSet("coord_access_token", tokens.accessToken)
        keychainSet("coord_refresh_token", tokens.refreshToken)
        keychainSet("coord_access_token_expires_at", String(tokens.accessTokenExpiresAt))
        keychainSet("coord_device_id", tokens.deviceId)
        keychainSet("coord_account_id", tokens.accountId)
        keychainSet("coord_history_limit", String(tokens.historyLimit))
    }

    func replaceTokens(
        _ tokens: CoordinationTokens,
        ifCurrentMatches expected: CoordinationTokens
    ) -> Bool {
        lock.withLock {
            guard loadTokensLocked() == expected else { return false }
            saveTokensLocked(tokens)
            return true
        }
    }

    func clearTokens() {
        lock.withLock { clearTokensLocked() }
    }

    private func clearTokensLocked() {
        keychainDelete("coord_access_token")
        keychainDelete("coord_refresh_token")
        keychainDelete("coord_access_token_expires_at")
        keychainDelete("coord_device_id")
        keychainDelete("coord_account_id")
        keychainDelete("coord_history_limit")
    }

    func clearTokens(ifCurrentMatches expected: CoordinationTokens) -> Bool {
        lock.withLock {
            guard loadTokensLocked() == expected else { return false }
            clearTokensLocked()
            return true
        }
    }

    func loadConfig() -> CoordinationConfig? {
        guard let serverUrl = defaults.string(forKey: "coord_server_url"),
              let identityUrl = defaults.string(forKey: "coord_identity_url") else {
            return nil
        }
        return CoordinationConfig(serverUrl: serverUrl, identityUrl: identityUrl)
    }

    func saveConfig(_ config: CoordinationConfig) {
        defaults.set(config.serverUrl, forKey: "coord_server_url")
        defaults.set(config.identityUrl, forKey: "coord_identity_url")
    }
}
