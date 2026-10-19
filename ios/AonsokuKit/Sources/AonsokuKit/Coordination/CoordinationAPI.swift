import Foundation

// Internal contract between `CoordinationService` and the coordination
// server's REST API (`/v1/*`). Mirrors `src/coordination/httpClient.ts`.

/// Tokens the coordination server issued to this device.
struct CoordinationTokens: Equatable, Sendable {
    var deviceId: String
    var accountId: String
    var accessToken: String
    var refreshToken: String
    /// Milliseconds since 1970, matching the previous app's stored value.
    var accessTokenExpiresAt: Double
    var historyLimit: Int

    init(
        deviceId: String,
        accountId: String,
        accessToken: String,
        refreshToken: String,
        accessTokenExpiresAt: Double,
        historyLimit: Int = 100
    ) {
        self.deviceId = deviceId
        self.accountId = accountId
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.historyLimit = historyLimit
    }
}

/// Subsonic identity proof sent during registration and refresh-token
/// recovery.
struct CoordinationSubsonicProof: Equatable, Sendable {
    var identityUrl: String
    var username: String
    /// "token" or "password".
    var authMode: String
    var token: String?
    var salt: String?
    var password: String?

    init(
        identityUrl: String,
        username: String,
        authMode: String,
        token: String? = nil,
        salt: String? = nil,
        password: String? = nil
    ) {
        self.identityUrl = identityUrl
        self.username = username
        self.authMode = authMode
        self.token = token
        self.salt = salt
        self.password = password
    }

    /// Builds the proof from stored Subsonic credentials. Token credentials
    /// send the stored MD5 token with the client's fixed salt; password
    /// credentials send the stored password. Returns nil for any other auth
    /// type.
    init?(identityUrl: String, credentials: ServerCredentials) {
        switch credentials.authType {
        case "token":
            self.init(
                identityUrl: identityUrl,
                username: credentials.username,
                authMode: "token",
                token: credentials.password,
                salt: SubsonicAuthBuilder.salt
            )
        case "password":
            self.init(
                identityUrl: identityUrl,
                username: credentials.username,
                authMode: "password",
                password: credentials.password
            )
        default:
            return nil
        }
    }
}

/// This device's description sent with registration.
struct CoordinationDeviceRegistration: Equatable, Sendable {
    var deviceName: String
    var platform: String
    var clientVersion: String
    var capabilities: Int
}

/// Performs one HTTP exchange. Injected so tests never touch the network.
typealias CoordinationTransport =
    @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// REST access to the coordination server. Implementations attach the bearer
/// token, refresh it when it expires within 60 seconds or a request returns
/// 401, persist rotated tokens through the token store, and throw
/// `CoordinationError` carrying the server's `code`, `reason` and HTTP status.
protocol CoordinationAPIClient: AnyObject, Sendable {
    /// Requests a challenge, then registers this device. The returned tokens
    /// are already persisted.
    func register(
        proof: CoordinationSubsonicProof,
        device: CoordinationDeviceRegistration
    ) async throws -> CoordinationTokens

    /// Issues a one-time WebSocket ticket.
    func webSocketTicket() async throws -> String

    func listDevices() async throws -> [CoordinationDevice]

    func renameDevice(id: String, name: String) async throws -> CoordinationDevice

    func revokeDevice(id: String) async throws

    func deleteAccount() async throws
}

/// Persists coordination tokens (keychain) and server config
/// (UserDefaults) under the previous app's keys.
protocol CoordinationTokenStoring: AnyObject, Sendable {
    func loadTokens() -> CoordinationTokens?
    func saveTokens(_ tokens: CoordinationTokens)
    func clearTokens()
    func loadConfig() -> CoordinationConfig?
    func saveConfig(_ config: CoordinationConfig)
}
