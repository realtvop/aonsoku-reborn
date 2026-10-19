import Foundation

/// `CoordinationAPIClient` over HTTPS. Port of
/// `src/coordination/httpClient.ts`.
final class CoordinationHTTPClient: CoordinationAPIClient, @unchecked Sendable {
    private let baseURL: String
    private let tokenStore: CoordinationTokenStoring
    private let recoveryProof: @Sendable () -> CoordinationSubsonicProof?
    private let transport: CoordinationTransport
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var refreshTask: Task<Void, Error>?
    private var refreshTaskGen: Int = 0

    /// - Parameters:
    ///   - baseURL: The coordination server URL; a trailing slash is ignored.
    ///   - tokenStore: Supplies the current tokens and persists rotated or
    ///     cleared ones.
    ///   - recoveryProof: Builds a proof from the current Subsonic
    ///     credentials when the server rejects the refresh token; nil when
    ///     none are available.
    ///   - transport: Performs requests; defaults to `URLSession.shared`.
    ///   - now: Clock used for token expiry.
    init(
        baseURL: String,
        tokenStore: CoordinationTokenStoring,
        recoveryProof: @escaping @Sendable () -> CoordinationSubsonicProof?,
        transport: @escaping CoordinationTransport = CoordinationHTTPClient.urlSessionTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.tokenStore = tokenStore
        self.recoveryProof = recoveryProof
        self.transport = transport
        self.now = now
    }

    static let urlSessionTransport: CoordinationTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoordinationError(code: CoordinationErrorCode.internal)
        }
        return (data, http)
    }

    // MARK: - Private Helpers

    private func nowMs() -> Double {
        now().timeIntervalSince1970 * 1000
    }

    private func buildRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        requireAuth: Bool = false
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw CoordinationError(code: CoordinationErrorCode.internal, reason: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if requireAuth {
            guard let tokens = tokenStore.loadTokens() else {
                throw CoordinationError(code: CoordinationErrorCode.notConnected)
            }
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = body
        }

        return request
    }

    private func performRequest<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        requireAuth: Bool = false
    ) async throws -> T {
        if requireAuth {
            try await refreshIfNeeded(force: false, sentAccessToken: nil)
        }
        var request = try buildRequest(path: path, method: method, body: body, requireAuth: requireAuth)

        do {
            let (data, response) = try await transport(request)

            if response.statusCode == 401, requireAuth {
                // Compare against the token this request carried, so a 401
                // that raced another caller's refresh reuses the new token.
                let sentAccessToken = request
                    .value(forHTTPHeaderField: "Authorization")
                    .map { String($0.dropFirst("Bearer ".count)) }
                try await refreshIfNeeded(force: true, sentAccessToken: sentAccessToken)
                request = try buildRequest(path: path, method: method, body: body, requireAuth: requireAuth)
                let (retryData, retryResponse) = try await transport(request)
                return try decodeResponse(data: retryData, response: retryResponse)
            }

            return try decodeResponse(data: data, response: response)
        } catch let error as CoordinationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CoordinationError(code: CoordinationErrorCode.internal, reason: error.localizedDescription)
        }
    }

    private func decodeResponse<T: Decodable>(
        data: Data,
        response: HTTPURLResponse
    ) throws -> T {
        guard response.statusCode >= 200, response.statusCode < 300 else {
            let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            let code = errorResponse?.code ?? CoordinationErrorCode.internal
            let reason = errorResponse?.reason ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw CoordinationError(code: code, reason: reason, status: response.statusCode)
        }

        if response.statusCode == 204 || data.isEmpty {
            if T.self == Empty.self {
                return Empty() as! T
            }
            throw CoordinationError(code: CoordinationErrorCode.internal, reason: "Expected decodable but got empty response")
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Refreshes the access token when it expires within 60 seconds, or
    /// unconditionally when `force` is set and the stored token is still the
    /// one `sentAccessToken` names. Concurrent callers share one in-flight
    /// refresh and observe its error.
    private func refreshIfNeeded(force: Bool, sentAccessToken: String?) async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if let refreshTask { return refreshTask }
            guard let tokens = tokenStore.loadTokens() else { return nil }
            if force {
                if let sentAccessToken, sentAccessToken != tokens.accessToken {
                    return nil
                }
            } else if tokens.accessTokenExpiresAt - nowMs() > 60_000 {
                return nil
            }

            refreshTaskGen += 1
            let generation = refreshTaskGen
            let task = Task<Void, Error> {
                defer {
                    self.lock.withLock {
                        if self.refreshTaskGen == generation {
                            self.refreshTask = nil
                        }
                    }
                }
                try await self.refreshTokens()
            }
            refreshTask = task
            return task
        }
        try await task?.value
    }

    private func refreshTokens() async throws {
        guard let tokens = tokenStore.loadTokens() else { return }

        let request = TokenRefreshRequest(
            deviceId: tokens.deviceId,
            refreshToken: tokens.refreshToken,
            challengeId: nil,
            identityUrl: nil,
            username: nil,
            authMode: nil,
            token: nil,
            salt: nil,
            password: nil
        )

        do {
            let response: TokenRefreshResponse = try await performTokenRefreshRequest(request, requireAuth: false)
            try await applyTokenRefreshResponse(response, existingTokens: tokens)
        } catch let error as CoordinationError {
            if error.code == CoordinationErrorCode.deviceRevoked {
                tokenStore.clearTokens()
                throw error
            } else if error.code == CoordinationErrorCode.authenticationFailed {
                try await recoverTokens(deviceId: tokens.deviceId, refreshToken: tokens.refreshToken)
            } else {
                throw error
            }
        }
    }

    private func recoverTokens(deviceId: String, refreshToken: String) async throws {
        guard let proof = recoveryProof() else {
            throw CoordinationError(
                code: CoordinationErrorCode.authenticationFailed,
                reason: "invalid refresh token",
                status: 401
            )
        }

        do {
            let challengeRequest = ChallengeRequest(
                identityUrl: proof.identityUrl,
                username: proof.username
            )
            let challenge: ChallengeResponse = try await performRequest(
                path: "/v1/auth/challenge",
                method: "POST",
                body: try JSONEncoder().encode(challengeRequest),
                requireAuth: false
            )

            let tokenRequest = TokenRefreshRequest(
                deviceId: deviceId,
                refreshToken: refreshToken,
                challengeId: challenge.challengeId,
                identityUrl: proof.identityUrl,
                username: proof.username,
                authMode: proof.authMode,
                token: proof.token,
                salt: proof.salt,
                password: proof.password
            )

            let response: TokenRefreshResponse = try await performTokenRefreshRequest(
                tokenRequest,
                requireAuth: false
            )

            guard let tokens = tokenStore.loadTokens() else {
                throw CoordinationError(code: CoordinationErrorCode.internal)
            }
            try await applyTokenRefreshResponse(response, existingTokens: tokens)
        } catch let error as CoordinationError {
            if error.code == CoordinationErrorCode.deviceRevoked {
                tokenStore.clearTokens()
            }
            throw error
        }
    }

    private func performTokenRefreshRequest(
        _ request: TokenRefreshRequest,
        requireAuth: Bool
    ) async throws -> TokenRefreshResponse {
        let body = try JSONEncoder().encode(request)
        return try await performRequest(
            path: "/v1/auth/token",
            method: "POST",
            body: body,
            requireAuth: requireAuth
        )
    }

    private func applyTokenRefreshResponse(
        _ response: TokenRefreshResponse,
        existingTokens: CoordinationTokens
    ) async throws {
        let updatedTokens = CoordinationTokens(
            deviceId: existingTokens.deviceId,
            accountId: existingTokens.accountId,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            accessTokenExpiresAt: nowMs() + Double(response.expiresIn) * 1000,
            historyLimit: existingTokens.historyLimit
        )
        tokenStore.saveTokens(updatedTokens)
    }

    // MARK: - CoordinationAPIClient

    func register(
        proof: CoordinationSubsonicProof,
        device: CoordinationDeviceRegistration
    ) async throws -> CoordinationTokens {
        let challengeRequest = ChallengeRequest(
            identityUrl: proof.identityUrl,
            username: proof.username
        )
        let challenge: ChallengeResponse = try await performRequest(
            path: "/v1/auth/challenge",
            method: "POST",
            body: try JSONEncoder().encode(challengeRequest),
            requireAuth: false
        )

        let registerRequest = RegisterRequest(
            challengeId: challenge.challengeId,
            identityUrl: proof.identityUrl,
            username: proof.username,
            authMode: proof.authMode,
            token: proof.token,
            salt: proof.salt,
            password: proof.password,
            deviceName: device.deviceName,
            platform: device.platform,
            clientVersion: device.clientVersion,
            capabilities: device.capabilities
        )

        let response: RegisterResponse = try await performRequest(
            path: "/v1/auth/register",
            method: "POST",
            body: try JSONEncoder().encode(registerRequest),
            requireAuth: false
        )

        let tokens = CoordinationTokens(
            deviceId: response.deviceId,
            accountId: response.accountId,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            accessTokenExpiresAt: nowMs() + Double(response.expiresIn) * 1000,
            historyLimit: response.historyLimit ?? 100
        )

        tokenStore.saveTokens(tokens)
        return tokens
    }

    func webSocketTicket() async throws -> String {
        struct TicketResponse: Decodable {
            let ticket: String
        }
        let response: TicketResponse = try await performRequest(
            path: "/v1/auth/ws-ticket",
            method: "POST",
            body: try JSONEncoder().encode([:] as [String: String]),
            requireAuth: true
        )
        return response.ticket
    }

    func listDevices() async throws -> [CoordinationDevice] {
        return try await performRequest(
            path: "/v1/devices",
            method: "GET",
            requireAuth: true
        )
    }

    func renameDevice(id: String, name: String) async throws -> CoordinationDevice {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        let body = try JSONEncoder().encode(["name": name])
        return try await performRequest(
            path: "/v1/devices/\(encodedId)",
            method: "PATCH",
            body: body,
            requireAuth: true
        )
    }

    func revokeDevice(id: String) async throws {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        let _: Empty = try await performRequest(
            path: "/v1/devices/\(encodedId)",
            method: "DELETE",
            requireAuth: true
        )
    }

    func deleteAccount() async throws {
        let _: Empty = try await performRequest(
            path: "/v1/account",
            method: "DELETE",
            requireAuth: true
        )
    }
}

// MARK: - DTOs

private struct ChallengeRequest: Codable {
    let identityUrl: String
    let username: String
}

private struct ChallengeResponse: Codable {
    let challengeId: String
}

private struct RegisterRequest: Codable {
    let challengeId: String
    let identityUrl: String
    let username: String
    let authMode: String
    let token: String?
    let salt: String?
    let password: String?
    let deviceName: String
    let platform: String
    let clientVersion: String?
    let capabilities: Int

    enum CodingKeys: String, CodingKey {
        case challengeId
        case identityUrl
        case username
        case authMode
        case token
        case salt
        case password
        case deviceName
        case platform
        case clientVersion
        case capabilities
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challengeId, forKey: .challengeId)
        try container.encode(identityUrl, forKey: .identityUrl)
        try container.encode(username, forKey: .username)
        try container.encode(authMode, forKey: .authMode)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(salt, forKey: .salt)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try container.encode(capabilities, forKey: .capabilities)
    }
}

private struct RegisterResponse: Codable {
    let deviceId: String
    let accountId: String
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let historyLimit: Int?
}

private struct TokenRefreshRequest: Codable {
    let deviceId: String
    let refreshToken: String
    let challengeId: String?
    let identityUrl: String?
    let username: String?
    let authMode: String?
    let token: String?
    let salt: String?
    let password: String?

    enum CodingKeys: String, CodingKey {
        case deviceId
        case refreshToken
        case challengeId
        case identityUrl
        case username
        case authMode
        case token
        case salt
        case password
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encodeIfPresent(challengeId, forKey: .challengeId)
        try container.encodeIfPresent(identityUrl, forKey: .identityUrl)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(authMode, forKey: .authMode)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(salt, forKey: .salt)
        try container.encodeIfPresent(password, forKey: .password)
    }
}

private struct TokenRefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

private struct ErrorResponse: Codable {
    let code: String?
    let reason: String?
}

private struct Empty: Codable {}
