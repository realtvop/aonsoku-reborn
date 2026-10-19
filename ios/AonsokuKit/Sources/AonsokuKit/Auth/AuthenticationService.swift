import Foundation

public final class AuthenticationService: @unchecked Sendable {
    public static let shared = AuthenticationService()

    private let httpClient = SubsonicHTTPClient()

    private init() {}

    // MARK: - Credential Management

    /// Store server credentials in the keychain.
    public func storeCredentials(_ credentials: ServerCredentials) throws {
        try KeychainManager.store(credentials)
    }

    /// Retrieve stored server credentials.
    public func getCredentials() -> ServerCredentials? {
        KeychainManager.retrieve()
    }

    /// Check if credentials are stored.
    public func hasCredentials() -> Bool {
        KeychainManager.exists()
    }

    /// Clear stored credentials from the keychain.
    public func clearCredentials() {
        KeychainManager.delete()
    }

    // MARK: - Login & Server Validation

    /// Perform login with username and password, probing both primary and fallback URLs.
    /// Returns login result with authType, protocol version, server type, and active URL.
    public func login(
        primaryUrl: String,
        fallbackUrl: String?,
        username: String,
        rawPassword: String
    ) async -> LoginResult {
        // Try primary URL with both auth types
        for authType in ["token", "password"] {
            let hashedPassword = SubsonicAuthBuilder.hashPasswordForStorage(
                rawPassword: rawPassword,
                authType: authType
            )

            let result = await httpClient.ping(
                baseUrl: primaryUrl,
                username: username,
                password: hashedPassword,
                authType: authType
            )

            if result.reachable {
                let serverInfo = await httpClient.queryServerInfo(baseUrl: primaryUrl)

                let credentials = ServerCredentials(
                    serverUrl: primaryUrl,
                    username: username,
                    password: hashedPassword,
                    authType: authType,
                    protocolVersion: serverInfo.protocolVersion,
                    serverType: serverInfo.serverType,
                    fallbackUrl: fallbackUrl
                )
                do {
                    try KeychainManager.store(credentials)
                } catch {
                    return LoginResult(
                        success: false,
                        error: "keychain_store_failed: \(error.localizedDescription)"
                    )
                }

                return LoginResult(
                    success: true,
                    authType: authType,
                    protocolVersion: serverInfo.protocolVersion,
                    serverType: serverInfo.serverType,
                    activeUrl: primaryUrl,
                    activeServerType: "primary",
                    password: hashedPassword
                )
            }
        }

        // Try fallback URL with both auth types
        if let fallbackUrl = fallbackUrl, !fallbackUrl.isEmpty {
            for authType in ["token", "password"] {
                let hashedPassword = SubsonicAuthBuilder.hashPasswordForStorage(
                    rawPassword: rawPassword,
                    authType: authType
                )

                let result = await httpClient.ping(
                    baseUrl: fallbackUrl,
                    username: username,
                    password: hashedPassword,
                    authType: authType
                )

                if result.reachable {
                    let serverInfo = await httpClient.queryServerInfo(baseUrl: fallbackUrl)

                    let credentials = ServerCredentials(
                        serverUrl: fallbackUrl,
                        username: username,
                        password: hashedPassword,
                        authType: authType,
                        protocolVersion: serverInfo.protocolVersion,
                        serverType: serverInfo.serverType,
                        fallbackUrl: nil
                    )
                    do {
                        try KeychainManager.store(credentials)
                    } catch {
                        return LoginResult(
                            success: false,
                            error: "keychain_store_failed: \(error.localizedDescription)"
                        )
                    }

                    return LoginResult(
                        success: true,
                        authType: authType,
                        protocolVersion: serverInfo.protocolVersion,
                        serverType: serverInfo.serverType,
                        activeUrl: fallbackUrl,
                        activeServerType: "fallback",
                        password: hashedPassword
                    )
                }
            }
        }

        return LoginResult(success: false, error: "auth_failed")
    }

    /// Verify a server is reachable with given credentials.
    public func ping(
        baseUrl: String,
        username: String,
        password: String,
        authType: String
    ) async -> (reachable: Bool, error: String?) {
        await httpClient.ping(
            baseUrl: baseUrl,
            username: username,
            password: password,
            authType: authType
        )
    }

    /// Query basic server information.
    public func queryServerInfo(baseUrl: String) async -> (protocolVersion: String, serverType: String) {
        await httpClient.queryServerInfo(baseUrl: baseUrl)
    }

    /// Perform an authenticated API request.
    public func request(
        path: String,
        query: [String: String] = [:],
        method: String = "GET"
    ) async throws -> SubsonicResponse {
        guard let credentials = KeychainManager.retrieve() else {
            throw AuthenticationError.noStoredCredentials
        }

        return try await httpClient.request(
            baseUrl: credentials.serverUrl,
            path: path,
            credentials: credentials,
            extraQuery: query,
            method: method
        )
    }

    // MARK: - URL Builders

    /// Build an authenticated URL for a Subsonic endpoint relative to
    /// `<server>/rest/`, preserving any base path in the stored server URL.
    public func url(path: String, query: [String: String] = [:]) -> URL? {
        guard let credentials = KeychainManager.retrieve() else { return nil }
        return try? httpClient.buildURL(
            baseUrl: credentials.serverUrl,
            path: path,
            credentials: credentials,
            extraQuery: query
        )
    }

    /// Build an authenticated stream URL for a song ID.
    public func streamURL(songId: String) -> URL? {
        url(path: "stream.view", query: ["id": songId])
    }

    /// Build an authenticated cover art URL.
    public func coverArtURL(id: String, size: Int = 300) -> URL? {
        url(path: "getCoverArt.view", query: ["id": id, "size": "\(size)"])
    }

    /// Build an authenticated avatar URL.
    public func avatarURL(username: String, size: Int = 300) -> URL? {
        url(path: "getAvatar.view", query: ["username": username, "size": "\(size)"])
    }

    /// Build an authenticated download URL for a song ID.
    public func downloadURL(id: String) -> URL? {
        url(path: "download.view", query: ["id": id])
    }
}

// MARK: - Result Types

public struct LoginResult {
    public let success: Bool
    public let authType: String?
    public let protocolVersion: String?
    public let serverType: String?
    public let activeUrl: String?
    public let activeServerType: String?
    public let password: String?
    public let error: String?

    init(
        success: Bool,
        authType: String? = nil,
        protocolVersion: String? = nil,
        serverType: String? = nil,
        activeUrl: String? = nil,
        activeServerType: String? = nil,
        password: String? = nil,
        error: String? = nil
    ) {
        self.success = success
        self.authType = authType
        self.protocolVersion = protocolVersion
        self.serverType = serverType
        self.activeUrl = activeUrl
        self.activeServerType = activeServerType
        self.password = password
        self.error = error
    }
}

public enum AuthenticationError: LocalizedError {
    case noStoredCredentials

    public var errorDescription: String? {
        switch self {
        case .noStoredCredentials:
            return "No stored credentials found"
        }
    }
}
