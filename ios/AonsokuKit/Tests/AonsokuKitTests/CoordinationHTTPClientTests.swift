import XCTest
@testable import AonsokuKit

final class CoordinationHTTPClientTests: XCTestCase {
    fileprivate var tokenStore: InMemoryTokenStore!
    fileprivate var fakeTransport: FakeTransport!
    fileprivate var client: CoordinationHTTPClient!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tokenStore = InMemoryTokenStore()
        fakeTransport = FakeTransport()
        testDefaults = UserDefaults(suiteName: "com.test.aonsoku.coordination")
        testDefaults?.removePersistentDomain(forName: "com.test.aonsoku.coordination")

        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        client = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com/",
            tokenStore: tokenStore,
            recoveryProof: { nil },
            transport: { request in
                try await self.fakeTransport.perform(request)
            },
            now: { fixedDate }
        )
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: "com.test.aonsoku.coordination")
        super.tearDown()
    }

    // MARK: - Register

    func testRegisterSendsChallengeRequest() async throws {
        let proof = CoordinationSubsonicProof(
            identityUrl: "https://example.com/subsonic",
            username: "testuser",
            authMode: "password",
            password: "testpass"
        )
        let device = CoordinationDeviceRegistration(
            deviceName: "Test iPhone",
            platform: "ios",
            clientVersion: "1.0",
            capabilities: 15
        )

        let challengeData: [String: String] = ["challengeId": "ch-123"]
        fakeTransport.addResponse(
            path: "/v1/auth/challenge",
            method: "POST",
            statusCode: 200,
            body: try JSONEncoder().encode(challengeData)
        )

        let registerData: [String: Any] = [
            "deviceId": "dev-123",
            "accountId": "acc-123",
            "accessToken": "access-123",
            "refreshToken": "refresh-123",
            "expiresIn": 3600,
            "historyLimit": 100,
        ]
        fakeTransport.addResponse(
            path: "/v1/auth/register",
            method: "POST",
            statusCode: 200,
            body: try JSONSerialization.data(withJSONObject: registerData)
        )

        let tokens = try await client.register(proof: proof, device: device)

        XCTAssertEqual(tokens.deviceId, "dev-123")
        XCTAssertEqual(tokens.accountId, "acc-123")
        XCTAssertEqual(tokens.accessToken, "access-123")
        XCTAssertEqual(tokens.refreshToken, "refresh-123")

        let requests = fakeTransport.recordedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/v1/auth/challenge")
        XCTAssertEqual(requests[1].url?.path, "/v1/auth/register")
    }

    func testRegisterReturnsTokensWithoutPersistingThem() async throws {
        let proof = CoordinationSubsonicProof(
            identityUrl: "https://example.com/subsonic",
            username: "testuser",
            authMode: "token",
            token: "mytoken",
            salt: "salt"
        )
        let device = CoordinationDeviceRegistration(
            deviceName: "iPad",
            platform: "ios",
            clientVersion: "1.0",
            capabilities: 15
        )

        fakeTransport.addResponse(path: "/v1/auth/challenge", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: ["challengeId": "ch-456"]))
        fakeTransport.addResponse(path: "/v1/auth/register", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "deviceId": "dev-456",
                                     "accountId": "acc-456",
                                     "accessToken": "access-456",
                                     "refreshToken": "refresh-456",
                                     "expiresIn": 7200,
                                 ] ))

        let tokens = try await client.register(proof: proof, device: device)

        XCTAssertEqual(tokens.deviceId, "dev-456")
        XCTAssertEqual(tokens.accountId, "acc-456")
        XCTAssertNil(tokenStore.loadTokens())
    }

    // MARK: - Bearer Token

    func testAuthenticatedRequestSendsBearerToken() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token-abc",
            refreshToken: "refresh-xyz",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let _ = try await client.listDevices()

        let request = fakeTransport.recordedRequests.first!
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-abc")
    }

    func testAuthenticatedRequestThrowsWithoutTokens() async throws {
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        do {
            let _ = try await client.listDevices()
            XCTFail("Should throw notConnected error")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.notConnected)
        }
    }

    // MARK: - Token Refresh

    func testRefreshWithin60SecondsOfExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let expiresAt = now.addingTimeInterval(30).timeIntervalSince1970 * 1000

        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "old-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: expiresAt,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "accessToken": "new-token",
                                     "refreshToken": "new-refresh",
                                     "expiresIn": 3600,
                                 ]))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let _ = try await client.listDevices()

        let requests = fakeTransport.recordedRequests
        // First request is token refresh, second is listDevices
        XCTAssertEqual(requests[0].url?.path, "/v1/auth/token")
        XCTAssertEqual(requests[1].url?.path, "/v1/devices")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
    }

    func testNoRefreshWhenTokenExpiresAfter60Seconds() async throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let expiresAt = now.addingTimeInterval(120).timeIntervalSince1970 * 1000

        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "valid-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: expiresAt,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let _ = try await client.listDevices()

        let requests = fakeTransport.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/v1/devices")
    }

    // MARK: - 401 Refresh and Retry

    func testOn401RefreshesAndRetries() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "expired-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 401,
                                 body: Data())
        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "accessToken": "refreshed-token",
                                     "refreshToken": "new-refresh",
                                     "expiresIn": 3600,
                                 ]))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let _ = try await client.listDevices()

        let requests = fakeTransport.recordedRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/v1/devices")
        XCTAssertEqual(requests[1].url?.path, "/v1/auth/token")
        XCTAssertEqual(requests[2].url?.path, "/v1/devices")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-token")
    }

    func testSecond401Throws() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "bad-token",
            refreshToken: "bad-refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 401,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "code": "authentication_failed",
                                     "reason": "Invalid token",
                                 ]))
        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "accessToken": "new-token",
                                     "refreshToken": "new-refresh",
                                     "expiresIn": 3600,
                                 ]))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 401,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "code": "authentication_failed",
                                     "reason": "Still invalid",
                                 ]))

        do {
            let _ = try await client.listDevices()
            XCTFail("Should throw authentication_failed")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.authenticationFailed)
        }
    }

    // MARK: - Concurrent Refreshes

    func testConcurrentCallsCoalesceRefresh() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "old-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: 1700000030000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "accessToken": "new-token",
                                     "refreshToken": "new-refresh",
                                     "expiresIn": 3600,
                                 ]))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        async let call1 = client.listDevices()
        async let call2 = client.listDevices()
        let _ = try await (call1, call2)

        let requests = fakeTransport.recordedRequests
        // One refresh + two listDevices calls
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/v1/auth/token")
    }

    func testStaleRefreshCannotReplaceNewAccountTokens() async throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let oldTokens = CoordinationTokens(
            deviceId: "old-device",
            accountId: "old-account",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: now.timeIntervalSince1970 * 1000,
            historyLimit: 100
        )
        let newTokens = CoordinationTokens(
            deviceId: "new-device",
            accountId: "new-account",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            accessTokenExpiresAt: now.addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            historyLimit: 200
        )
        tokenStore.saveTokens(oldTokens)
        let refreshStarted = expectation(description: "refresh started")
        let gate = AsyncGate()
        let responseData = try JSONSerialization.data(withJSONObject: [
            "accessToken": "stale-access",
            "refreshToken": "stale-refresh",
            "expiresIn": 3600,
        ])
        let testClient = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com",
            tokenStore: tokenStore,
            recoveryProof: { nil },
            transport: { request in
                refreshStarted.fulfill()
                await gate.wait()
                return (responseData, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            },
            now: { now }
        )

        let request = Task { try await testClient.listDevices() }
        await fulfillment(of: [refreshStarted], timeout: 1)
        tokenStore.saveTokens(newTokens)
        await gate.open()

        do {
            _ = try await request.value
            XCTFail("stale refresh should fail")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.notConnected)
        }
        XCTAssertEqual(tokenStore.loadTokens(), newTokens)
    }

    // MARK: - Device Revoked

    func testDeviceRevokedClearsTokens() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "valid-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: 1700000030000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 403,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "code": "device_revoked",
                                     "reason": "Device was revoked",
                                 ]))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        do {
            let _ = try await client.listDevices()
            XCTFail("Should throw device_revoked")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.deviceRevoked)
        }

        XCTAssertNil(tokenStore.loadTokens())
    }

    func testStaleRevocationCannotClearNewAccountTokens() async throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let oldTokens = CoordinationTokens(
            deviceId: "old-device",
            accountId: "old-account",
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt: now.timeIntervalSince1970 * 1000,
            historyLimit: 100
        )
        let newTokens = CoordinationTokens(
            deviceId: "new-device",
            accountId: "new-account",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            accessTokenExpiresAt: now.addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            historyLimit: 200
        )
        tokenStore.saveTokens(oldTokens)
        let refreshStarted = expectation(description: "refresh started")
        let gate = AsyncGate()
        let responseData = try JSONSerialization.data(withJSONObject: [
            "code": "device_revoked",
            "reason": "old device was revoked",
        ])
        let testClient = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com",
            tokenStore: tokenStore,
            recoveryProof: { nil },
            transport: { request in
                refreshStarted.fulfill()
                await gate.wait()
                return (responseData, HTTPURLResponse(
                    url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil
                )!)
            },
            now: { now }
        )

        let request = Task { try await testClient.listDevices() }
        await fulfillment(of: [refreshStarted], timeout: 1)
        tokenStore.saveTokens(newTokens)
        await gate.open()

        do {
            _ = try await request.value
            XCTFail("revoked refresh should fail")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.deviceRevoked)
        }
        XCTAssertEqual(tokenStore.loadTokens(), newTokens)
    }

    // MARK: - Authentication Failed Recovery

    func testAuthenticationFailedRecoveryWithProof() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "valid-token",
            refreshToken: "bad-refresh",
            accessTokenExpiresAt: 1700000030000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        let proof = CoordinationSubsonicProof(
            identityUrl: "https://example.com/subsonic",
            username: "user",
            authMode: "password",
            password: "pass"
        )

        client = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com",
            tokenStore: tokenStore,
            recoveryProof: { proof },
            transport: { request in
                try await self.fakeTransport.perform(request)
            },
            now: { Date(timeIntervalSince1970: 1700000000) }
        )

        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 401,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "code": "authentication_failed",
                                     "reason": "Invalid refresh token",
                                 ]))
        fakeTransport.addResponse(path: "/v1/auth/challenge", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "challengeId": "ch-recovery",
                                 ]))
        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "accessToken": "recovered-token",
                                     "refreshToken": "recovered-refresh",
                                     "expiresIn": 3600,
                                 ]))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let _ = try await client.listDevices()

        let loaded = tokenStore.loadTokens()
        XCTAssertEqual(loaded?.accessToken, "recovered-token")
    }

    func testAuthenticationFailedWithoutProofThrows() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "valid-token",
            refreshToken: "bad-refresh",
            accessTokenExpiresAt: 1700000030000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 401,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "code": "authentication_failed",
                                     "reason": "Invalid refresh token",
                                 ]))

        do {
            let _ = try await client.listDevices()
            XCTFail("Should throw authentication_failed")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.authenticationFailed)
            XCTAssertEqual(error.reason, "invalid refresh token")
            XCTAssertEqual(error.status, 401)
        }
    }

    // MARK: - Error Mapping

    func testErrorMappingWithJsonBody() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token",
            refreshToken: "refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 500,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "code": "internal_server_error",
                                     "reason": "Database connection failed",
                                 ]))

        do {
            let _ = try await client.listDevices()
            XCTFail("Should throw internal_server_error")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, "internal_server_error")
            XCTAssertEqual(error.reason, "Database connection failed")
            XCTAssertEqual(error.status, 500)
        }
    }

    func testErrorMappingWithoutJsonBody() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token",
            refreshToken: "refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 503,
                                 body: "Service Unavailable".data(using: .utf8)!)

        do {
            let _ = try await client.listDevices()
            XCTFail("Should throw error")
        } catch let error as CoordinationError {
            XCTAssertEqual(error.code, CoordinationErrorCode.internal)
            XCTAssertNotNil(error.reason)
            XCTAssertEqual(error.status, 503)
        }
    }

    // MARK: - URL Handling

    func testTrailingSlashRemovedFromBaseUrl() async throws {
        let tokensWithTrailingSlash = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token",
            refreshToken: "refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokensWithTrailingSlash)

        let clientWithSlash = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com/",
            tokenStore: tokenStore,
            recoveryProof: { nil },
            transport: { request in
                try await self.fakeTransport.perform(request)
            },
            now: { Date(timeIntervalSince1970: 1700000000) }
        )

        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let _ = try await clientWithSlash.listDevices()

        let request = fakeTransport.recordedRequests.first!
        XCTAssertEqual(request.url?.absoluteString, "https://coordination.example.com/v1/devices")
    }

    // MARK: - Device ID Encoding

    func testDeviceIdEncoding() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token",
            refreshToken: "refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices/special%2Fid", method: "PATCH", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: [
                                     "id": "special/id",
                                     "name": "Renamed",
                                     "platform": "ios",
                                     "capabilities": 15,
                                     "createdAt": "2023-01-01T00:00:00Z",
                                 ] ))

        let _ = try await client.renameDevice(id: "special/id", name: "Renamed")

        let request = fakeTransport.recordedRequests.first!
        XCTAssertTrue(request.url?.absoluteString.contains("special%2Fid") ?? false)
    }

    // MARK: - Token Store Key Names

    func testTokenStoreKeyNames() throws {
        var keysWritten: [String: String] = [:]
        let testAccess = CoordinationKeychainTokenStore.CoordinationKeychainAccess(
            get: { key in keysWritten[key] },
            set: { key, value in keysWritten[key] = value },
            delete: { key in keysWritten.removeValue(forKey: key) }
        )

        let store = CoordinationKeychainTokenStore(keychain: testAccess, defaults: testDefaults!)

        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token-abc",
            refreshToken: "refresh-xyz",
            accessTokenExpiresAt: 1700000000000,
            historyLimit: 50
        )

        store.saveTokens(tokens)

        XCTAssertEqual(keysWritten["coord_access_token"], "token-abc")
        XCTAssertEqual(keysWritten["coord_refresh_token"], "refresh-xyz")
        XCTAssertEqual(keysWritten["coord_device_id"], "dev-123")
        XCTAssertEqual(keysWritten["coord_account_id"], "acc-123")
        XCTAssertEqual(keysWritten["coord_access_token_expires_at"], "1700000000000.0")
        XCTAssertEqual(keysWritten["coord_history_limit"], "50")
    }

    func testConfigKeyNames() {
        let testDefaults = UserDefaults(suiteName: "com.test.coordination.config")!
        testDefaults.removePersistentDomain(forName: "com.test.coordination.config")

        let store = CoordinationKeychainTokenStore(
            keychain: CoordinationKeychainTokenStore.CoordinationKeychainAccess(
                get: { _ in nil },
                set: { _, _ in },
                delete: { _ in }
            ),
            defaults: testDefaults
        )

        let config = CoordinationConfig(
            serverUrl: "https://coord.example.com",
            identityUrl: "https://subsonic.example.com"
        )

        store.saveConfig(config)

        XCTAssertEqual(testDefaults.string(forKey: "coord_server_url"), "https://coord.example.com")
        XCTAssertEqual(testDefaults.string(forKey: "coord_identity_url"), "https://subsonic.example.com")

        testDefaults.removePersistentDomain(forName: "com.test.coordination.config")
    }

    // MARK: - 204 and Empty Responses

    func testRevokeDeviceOn204() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token",
            refreshToken: "refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/devices/dev-456", method: "DELETE", statusCode: 204,
                                 body: Data())

        try await client.revokeDevice(id: "dev-456")

        let requests = fakeTransport.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/v1/devices/dev-456")
    }

    func testDeleteAccountOn204() async throws {
        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "token",
            refreshToken: "refresh",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        fakeTransport.addResponse(path: "/v1/account", method: "DELETE", statusCode: 204,
                                 body: Data())

        try await client.deleteAccount()

        let requests = fakeTransport.recordedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.path, "/v1/account")
    }

    // MARK: - Concurrent 401 Handling

    func testConcurrent401TriggersOneRefresh() async throws {
        tokenStore.saveTokens(CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "expired-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: 1700003600000,
            historyLimit: 100
        ))
        let tokenData = try JSONSerialization.data(withJSONObject: [
            "accessToken": "refreshed-token",
            "refreshToken": "new-refresh",
            "expiresIn": 3600,
        ])
        let refreshCount = LockedCounter()

        // The server rejects the old token and accepts the refreshed one, so
        // the outcome does not depend on how the two calls interleave.
        let testClient = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com",
            tokenStore: tokenStore,
            recoveryProof: { nil },
            transport: { request in
                let url = request.url!
                if url.path == "/v1/auth/token" {
                    refreshCount.increment()
                    try await Task.sleep(nanoseconds: 50_000_000)
                    return (tokenData, HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!)
                }
                let authorized = request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer refreshed-token"
                return (authorized ? Data("[]".utf8) : Data(), HTTPURLResponse(
                    url: url,
                    statusCode: authorized ? 200 : 401,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            },
            now: { Date(timeIntervalSince1970: 1700000000) }
        )

        async let call1 = testClient.listDevices()
        async let call2 = testClient.listDevices()
        let (first, second) = try await (call1, call2)

        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        XCTAssertEqual(refreshCount.value, 1, "Should only refresh once for concurrent 401s")
    }

    // MARK: - Concurrent 60-Second Expiry Refresh

    func testConcurrentExpiryRefreshCoalesces() async throws {
        let now = Date(timeIntervalSince1970: 1700000000)
        let expiresAt = now.addingTimeInterval(30).timeIntervalSince1970 * 1000

        let tokens = CoordinationTokens(
            deviceId: "dev-123",
            accountId: "acc-123",
            accessToken: "old-token",
            refreshToken: "refresh-token",
            accessTokenExpiresAt: expiresAt,
            historyLimit: 100
        )
        tokenStore.saveTokens(tokens)

        let tokenData: [String: Any] = [
            "accessToken": "new-token",
            "refreshToken": "new-refresh",
            "expiresIn": 3600,
        ]

        fakeTransport.addResponse(path: "/v1/auth/token", method: "POST", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: tokenData))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))
        fakeTransport.addResponse(path: "/v1/devices", method: "GET", statusCode: 200,
                                 body: try JSONSerialization.data(withJSONObject: []))

        let testClient = CoordinationHTTPClient(
            baseURL: "https://coordination.example.com",
            tokenStore: tokenStore,
            recoveryProof: { nil },
            transport: { request in
                try await self.fakeTransport.perform(request)
            },
            now: { now }
        )

        async let call1 = testClient.listDevices()
        async let call2 = testClient.listDevices()
        let _ = try await (call1, call2)

        let requests = fakeTransport.recordedRequests
        var refreshCount = 0
        for request in requests {
            if request.url?.path == "/v1/auth/token" {
                refreshCount += 1
            }
        }
        XCTAssertEqual(refreshCount, 1, "Should only refresh once for concurrent expiry checks")
    }
}

// MARK: - Test Helpers

fileprivate final class InMemoryTokenStore: CoordinationTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: CoordinationTokens?
    private var config: CoordinationConfig?

    func loadTokens() -> CoordinationTokens? { lock.withLock { tokens } }
    func saveTokens(_ tokens: CoordinationTokens) { lock.withLock { self.tokens = tokens } }
    func replaceTokens(
        _ tokens: CoordinationTokens,
        ifCurrentMatches expected: CoordinationTokens
    ) -> Bool {
        lock.withLock {
            guard self.tokens == expected else { return false }
            self.tokens = tokens
            return true
        }
    }
    func clearTokens() { lock.withLock { tokens = nil } }
    func clearTokens(ifCurrentMatches expected: CoordinationTokens) -> Bool {
        lock.withLock {
            guard tokens == expected else { return false }
            tokens = nil
            return true
        }
    }
    func loadConfig() -> CoordinationConfig? { lock.withLock { config } }
    func saveConfig(_ config: CoordinationConfig) { lock.withLock { self.config = config } }
}

fileprivate final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}

fileprivate actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

fileprivate class FakeTransport {
    private struct Response {
        let statusCode: Int
        let body: Data
    }

    private var responseQueues: [String: [Response]] = [:]
    fileprivate var recordedRequests: [URLRequest] = []
    private let lock = NSLock()

    func addResponse(path: String, method: String, statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(method) \(path)"
        if responseQueues[key] == nil {
            responseQueues[key] = []
        }
        responseQueues[key]?.append(Response(statusCode: statusCode, body: body))
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path(percentEncoded: true))"
        let next: Response? = lock.withLock {
            recordedRequests.append(request)
            guard var queue = responseQueues[key], !queue.isEmpty else { return nil }
            let response = queue.removeFirst()
            responseQueues[key] = queue
            return response
        }
        guard let response = next else {
            throw CoordinationError(code: CoordinationErrorCode.internal, reason: "No response configured for \(key)")
        }

        guard let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw CoordinationError(code: CoordinationErrorCode.internal)
        }

        return (response.body, httpResponse)
    }
}

fileprivate class TestUserDefaults: UserDefaults {
    private var data: [String: Any]

    init(data: inout [String: Any]) {
        self.data = data
        super.init(suiteName: "test")!
    }

    override func string(forKey defaultName: String) -> String? {
        data[defaultName] as? String
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        data[defaultName] = value
    }
}
