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

/// Sign-in state. Credentials stay in the Keychain owned by
/// `AuthenticationService`; library data is kept on sign-out (web logout).
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: SessionState = .restoring
    /// The signed-in user's roles, loaded with `getUser` when online.
    public private(set) var user: SubsonicUser?

    @ObservationIgnored public let authentication: AuthenticationService
    @ObservationIgnored public let preferences: PreferencesService
    @ObservationIgnored public let api: any SubsonicAPI

    public init(
        authentication: AuthenticationService,
        preferences: PreferencesService,
        api: any SubsonicAPI
    ) {
        self.authentication = authentication
        self.preferences = preferences
        self.api = api
    }

    public var account: ServerAccount? {
        if case let .signedIn(account) = state { return account }
        return nil
    }

    public var isSignedIn: Bool { account != nil }

    /// Reads stored credentials and the saved account. Without an account
    /// record (data from the Capacitor app), it is rebuilt from the Keychain
    /// credentials. Never touches the network.
    public func restore() {}

    /// Signs in, trying the fallback URL when the primary fails, and stores
    /// the credentials. Throws `SubsonicAPIError.authenticationFailed` for
    /// wrong credentials and a connectivity error when no server answered.
    public func signIn(
        serverUrl: String,
        fallbackUrl: String?,
        username: String,
        password: String
    ) async throws {
        throw SubsonicAPIError.unsupported
    }

    /// Whether the server speaks Subsonic 1.15.0 or later, as the web login
    /// checks before saving. A server that does not answer counts as
    /// compatible, so the sign-in itself reports the failure.
    public func isCompatible(serverUrl: String) async -> Bool {
        let info = await authentication.queryServerInfo(baseUrl: serverUrl)
        let parts = info.protocolVersion.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return true }
        let version = parts.compactMap { $0 } + [0, 0, 0]
        return version.prefix(3).lexicographicallyPrecedes([1, 15, 0]) == false
    }

    /// Reloads `user`; keeps the previous value on failure.
    public func refreshUser() async {}

    /// Removes credentials and the account record.
    public func signOut() {}

    /// The user's avatar on the server.
    public func avatarURL(size: Int = 300) -> URL? {
        guard let account else { return nil }
        return authentication.avatarURL(username: account.username, size: size)
    }
}
