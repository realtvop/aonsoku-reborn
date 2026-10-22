import Foundation
import Observation

/// The signed-in server, persisted under `session.account.v1`. The Keychain
/// credentials hold the active URL; this keeps the primary and fallback
/// addresses the user entered.
public struct ServerAccount: Codable, Hashable, Sendable {
    public var primaryUrl: String
    public var fallbackUrl: String?
    /// The address that answered at sign-in: primary or fallback.
    public var activeUrl: String
    public var username: String
    /// `navidrome`, `lms`, `subsonic`, ...
    public var serverType: String
    public var protocolVersion: String
    /// `token` or `password`.
    public var authType: String

    public init(
        primaryUrl: String,
        fallbackUrl: String? = nil,
        activeUrl: String,
        username: String,
        serverType: String,
        protocolVersion: String,
        authType: String
    ) {
        self.primaryUrl = primaryUrl
        self.fallbackUrl = fallbackUrl
        self.activeUrl = activeUrl
        self.username = username
        self.serverType = serverType
        self.protocolVersion = protocolVersion
        self.authType = authType
    }

    public var isNavidrome: Bool { serverType.lowercased() == "navidrome" }
    public var isLMS: Bool { serverType.lowercased() == "lms" }
}

public enum SessionState: Hashable, Sendable {
    /// Reading stored credentials at launch.
    case restoring
    case signedOut
    case signedIn(ServerAccount)
}

public enum ServerCompatibility: Hashable, Sendable {
    case compatible
    case incompatible
    case unknown

    init(protocolVersion: String) {
        let parts = protocolVersion.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else {
            self = .unknown
            return
        }
        let version = parts.compactMap { $0 } + [0, 0, 0]
        self = version.prefix(3).lexicographicallyPrecedes([1, 15, 0])
            ? .incompatible
            : .compatible
    }

    public static func requiresOverride(
        primary: Self,
        fallback: Self?
    ) -> Bool {
        primary == .incompatible
            || (primary == .unknown && fallback == .incompatible)
    }
}

/// Sign-in state. Credentials stay in the Keychain owned by
/// `AuthenticationService`; library data is kept on sign-out (web logout).
@MainActor
@Observable
public final class SessionStore {
    public static let accountStorageKey = "session.account.v1"

    public private(set) var state: SessionState = .restoring
    /// The signed-in user's roles, loaded with `getUser` when online.
    public private(set) var user: SubsonicUser?

    @ObservationIgnored public let authentication: AuthenticationService
    @ObservationIgnored public let preferences: PreferencesService
    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored private let authenticationClient: SessionAuthenticationClient

    public init(
        authentication: AuthenticationService,
        preferences: PreferencesService,
        api: any SubsonicAPI
    ) {
        self.authentication = authentication
        self.preferences = preferences
        self.api = api
        self.authenticationClient = .live(authentication)
    }

    init(
        authentication: AuthenticationService = .shared,
        authenticationClient: SessionAuthenticationClient,
        preferences: PreferencesService,
        api: any SubsonicAPI
    ) {
        self.authentication = authentication
        self.authenticationClient = authenticationClient
        self.preferences = preferences
        self.api = api
    }

    public var account: ServerAccount? {
        if case let .signedIn(account) = state { return account }
        return nil
    }

    public var isSignedIn: Bool { account != nil }

    /// The fallback address answered at sign-in or after the last change.
    public var isUsingFallback: Bool {
        guard let account, let fallback = account.fallbackUrl, !fallback.isEmpty else {
            return false
        }
        return account.activeUrl == fallback && account.activeUrl != account.primaryUrl
    }

    /// Reads stored credentials and the saved account. Without an account
    /// record (data from the Capacitor app), it is rebuilt from the Keychain
    /// credentials. Never touches the network.
    public func restore() {
        if let saved = preferences.getJSON(Self.accountStorageKey, as: ServerAccount.self) {
            state = .signedIn(saved)
            return
        }

        guard let credentials = authenticationClient.getCredentials() else {
            state = .signedOut
            return
        }
        let account = ServerAccount(
            primaryUrl: credentials.serverUrl,
            fallbackUrl: credentials.fallbackUrl,
            activeUrl: credentials.serverUrl,
            username: credentials.username,
            serverType: credentials.serverType,
            protocolVersion: credentials.protocolVersion,
            authType: credentials.authType
        )
        try? preferences.setJSON(account, for: Self.accountStorageKey)
        state = .signedIn(account)
    }

    /// Signs in, trying the fallback URL when the primary fails, and stores
    /// the credentials. Throws `SubsonicAPIError.authenticationFailed` for
    /// wrong credentials and a connectivity error when no server answered.
    public func signIn(
        serverUrl: String,
        fallbackUrl: String?,
        username: String,
        password: String
    ) async throws {
        let primary = try normalizedServerURL(serverUrl)
        let fallback = try normalizedOptionalServerURL(fallbackUrl)
        state = .signedOut
        user = nil

        let result = await authenticationClient.login(
            primary,
            fallback,
            username,
            password
        )
        guard result.success,
              let activeUrl = result.activeUrl,
              let storedPassword = result.password,
              let authType = result.authType else {
            throw Self.loginError(result.error)
        }

        let account = ServerAccount(
            primaryUrl: primary,
            fallbackUrl: fallback,
            activeUrl: activeUrl,
            username: username,
            serverType: result.serverType ?? "subsonic",
            protocolVersion: result.protocolVersion ?? SubsonicAuthBuilder.defaultVersion,
            authType: authType
        )
        let credentials = ServerCredentials(
            serverUrl: activeUrl,
            username: username,
            password: storedPassword,
            authType: authType,
            protocolVersion: account.protocolVersion,
            serverType: account.serverType,
            fallbackUrl: fallback
        )
        do {
            try authenticationClient.storeCredentials(credentials)
            try preferences.setJSON(account, for: Self.accountStorageKey)
        } catch {
            throw SubsonicAPIError.invalidResponse(error.localizedDescription)
        }
        state = .signedIn(account)
    }

    /// Whether the server speaks Subsonic 1.15.0 or later, as the web login
    /// checks before saving. A server that does not answer counts as
    /// compatible, so the sign-in itself reports the failure.
    public func isCompatible(serverUrl: String) async -> Bool {
        let info = await authenticationClient.queryServerInfo(serverUrl)
        return ServerCompatibility(protocolVersion: info.protocolVersion) != .incompatible
    }

    public func compatibility(
        serverUrl: String,
        username: String,
        password: String
    ) async -> ServerCompatibility {
        await authenticationClient.probeCompatibility(
            serverUrl,
            username,
            password
        )
    }

    /// Reloads `user`; keeps the previous value on failure.
    public func refreshUser() async {
        guard let account else { return }
        if let refreshed = try? await api.user(username: account.username) {
            guard self.account == account else { return }
            user = refreshed
        }
    }

    /// Saves new server addresses (web `saveServerUrls`): the primary is
    /// tried first, then the fallback, with the stored credentials, and the
    /// one that answers becomes active. Throws when neither answers and
    /// keeps the previous addresses.
    public func updateServerUrls(primaryUrl: String, fallbackUrl: String?) async throws {
        guard let previous = account,
              let credentials = authenticationClient.getCredentials() else {
            throw SubsonicAPIError.notSignedIn
        }
        let primary = try normalizedServerURL(primaryUrl)
        let fallback = try normalizedOptionalServerURL(fallbackUrl)

        var failures: [String] = []
        var activeUrl: String?
        let primaryResult = await authenticationClient.ping(
            primary,
            credentials.username,
            credentials.password,
            credentials.authType
        )
        if primaryResult.reachable {
            activeUrl = primary
        } else if let error = primaryResult.error {
            failures.append(error)
        }

        if activeUrl == nil, let fallback {
            let fallbackResult = await authenticationClient.ping(
                fallback,
                credentials.username,
                credentials.password,
                credentials.authType
            )
            if fallbackResult.reachable {
                activeUrl = fallback
            } else if let error = fallbackResult.error {
                failures.append(error)
            }
        }

        guard let activeUrl else {
            throw Self.loginError(
                failures.contains("auth_failed") ? "auth_failed" : "network_unreachable"
            )
        }
        let info = try await authenticationClient.queryAuthenticatedServerInfo(
            activeUrl,
            credentials
        )
        let updated = ServerAccount(
            primaryUrl: primary,
            fallbackUrl: fallback,
            activeUrl: activeUrl,
            username: previous.username,
            serverType: info.serverType,
            protocolVersion: info.protocolVersion,
            authType: credentials.authType
        )
        let updatedCredentials = ServerCredentials(
            serverUrl: activeUrl,
            username: credentials.username,
            password: credentials.password,
            authType: credentials.authType,
            protocolVersion: info.protocolVersion,
            serverType: info.serverType,
            fallbackUrl: fallback
        )
        do {
            try authenticationClient.storeCredentials(updatedCredentials)
            try preferences.setJSON(updated, for: Self.accountStorageKey)
        } catch {
            throw SubsonicAPIError.invalidResponse(error.localizedDescription)
        }
        state = .signedIn(updated)
    }

    /// Pings the active server for its type and versions; nil when it does
    /// not answer.
    public func serverInfo() async -> ServerInfo? { try? await api.ping() }

    /// Removes credentials and the account record.
    public func signOut() {
        authenticationClient.clearCredentials()
        preferences.remove(Self.accountStorageKey)
        user = nil
        state = .signedOut
    }

    /// The user's avatar on the server.
    public func avatarURL(size: Int = 300) -> URL? {
        guard let account else { return nil }
        return authentication.avatarURL(username: account.username, size: size)
    }

    private func normalizedServerURL(_ value: String) throws -> String {
        let normalized = normalizeURL(value)
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw SubsonicAPIError.invalidResponse("Invalid server URL")
        }
        return normalized
    }

    private func normalizedOptionalServerURL(_ value: String?) throws -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try normalizedServerURL(value)
    }

    private func normalizeURL(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func loginError(_ error: String?) -> SubsonicAPIError {
        switch error {
        case "auth_failed":
            .authenticationFailed(message: "Authentication failed")
        case "network_unreachable", "server_error", nil:
            .offline
        default:
            .invalidResponse(error ?? "Login failed")
        }
    }
}

struct SessionAuthenticationClient: @unchecked Sendable {
    var getCredentials: () -> ServerCredentials?
    var storeCredentials: (ServerCredentials) throws -> Void
    var clearCredentials: () -> Void
    var login: (String, String?, String, String) async -> LoginResult
    var ping: (String, String, String, String) async -> (reachable: Bool, error: String?)
    var queryServerInfo: (String) async -> (protocolVersion: String, serverType: String)
    var queryAuthenticatedServerInfo: (
        String,
        ServerCredentials
    ) async throws -> (protocolVersion: String, serverType: String)
    var probeCompatibility: (String, String, String) async -> ServerCompatibility

    static func live(_ service: AuthenticationService) -> Self {
        Self(
            getCredentials: service.getCredentials,
            storeCredentials: service.storeCredentials,
            clearCredentials: service.clearCredentials,
            login: service.login,
            ping: service.ping,
            queryServerInfo: service.queryServerInfo,
            queryAuthenticatedServerInfo: service.queryAuthenticatedServerInfo,
            probeCompatibility: service.probeServerCompatibility
        )
    }
}
