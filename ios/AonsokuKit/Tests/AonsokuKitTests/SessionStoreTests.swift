import XCTest
@testable import AonsokuKit

@MainActor
final class SessionStoreTests: XCTestCase {
    func testFallbackNotificationInvalidatesOldPingAndAllowsNewServerCheck() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let account = makeAccount()
        try preferences.setJSON(account, for: SessionStore.accountStorageKey)
        let credentials = LockedTestBox(makeCredentials())
        let api = FakeSubsonicAPI()
        let store = makeStore(preferences: preferences, api: api,
                              client: makeClient(getCredentials: { credentials.read { $0 } }))
        store.restore()
        let started = expectation(description: "Original server ping started")
        let release = LockedTestBox<CheckedContinuation<ServerInfo, Error>?>(nil)
        api.pingHandler = {
            try await withCheckedThrowingContinuation { continuation in
                release.update { $0 = continuation }; started.fulfill()
            }
        }
        let oldCheck = Task { await store.checkServerConnection() }
        await fulfillment(of: [started], timeout: 1)
        credentials.update { old in
            old = ServerCredentials(serverUrl: account.fallbackUrl!, username: old.username, password: old.password,
                                    authType: old.authType, protocolVersion: old.protocolVersion,
                                    serverType: old.serverType, fallbackUrl: old.fallbackUrl)
        }
        NotificationCenter.default.post(name: .serverURLDidChange, object: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while store.account?.activeUrl != account.fallbackUrl, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(store.account?.activeUrl, account.fallbackUrl)
        XCTAssertEqual(store.account?.primaryUrl, account.primaryUrl)
        XCTAssertEqual(store.account?.username, account.username)
        XCTAssertTrue(store.isUsingFallback)
        release.read { $0 }?.resume(returning: ServerInfo(type: "navidrome", protocolVersion: "1.16.1"))
        await oldCheck.value
        XCTAssertEqual(store.serverConnection, .unchecked)
        api.pingHandler = { ServerInfo(type: "navidrome", protocolVersion: "1.16.1") }
        await store.checkServerConnection()
        XCTAssertEqual(store.serverConnection, .available)
    }

    func testAvatarConnectionRequiresAuthenticatedPingAndRecoversFromFailure() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        let store = makeStore(preferences: PreferencesService(db: database.manager.dbPool), api: api,
                              client: makeClient(getCredentials: { self.makeCredentials() }))
        store.restore()
        XCTAssertEqual(store.serverConnection, .unchecked)
        api.pingHandler = { throw SubsonicAPIError.timedOut }
        await store.checkServerConnection()
        XCTAssertEqual(store.serverConnection, .failed(SubsonicAPIError.timedOut.localizedDescription))
        api.pingHandler = { ServerInfo(type: "navidrome", protocolVersion: "1.16.1") }
        await store.checkServerConnection()
        XCTAssertEqual(store.serverConnection, .available)
    }

    func testLateServerPingCannotPublishAfterSignOut() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        let store = makeStore(preferences: PreferencesService(db: database.manager.dbPool), api: api,
                              client: makeClient(getCredentials: { self.makeCredentials() }))
        store.restore()
        let started = expectation(description: "Ping started")
        let release = LockedTestBox<CheckedContinuation<ServerInfo, Error>?>(nil)
        api.pingHandler = {
            try await withCheckedThrowingContinuation { continuation in
                release.update { $0 = continuation }; started.fulfill()
            }
        }
        let check = Task { await store.checkServerConnection() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(store.serverConnection, .checking)
        store.signOut()
        release.read { $0 }?.resume(returning: ServerInfo(type: "navidrome", protocolVersion: "1.16.1"))
        await check.value
        XCTAssertEqual(store.serverConnection, .unchecked)
    }

    func testCanceledAvatarCheckDoesNotReportServerFailure() async throws {
        let database = try TemporaryDatabase()
        let api = FakeSubsonicAPI()
        let store = makeStore(preferences: PreferencesService(db: database.manager.dbPool), api: api,
                              client: makeClient(getCredentials: { self.makeCredentials() }))
        store.restore()
        api.pingHandler = { throw CancellationError() }
        await store.checkServerConnection()
        XCTAssertEqual(store.serverConnection, .unchecked)
    }

    func testRestorePrefersAccountRecordWhenCredentialsAreLocked() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let account = makeAccount()
        try preferences.setJSON(account, for: SessionStore.accountStorageKey)
        let reads = LockedTestBox(0)
        let store = makeStore(
            preferences: preferences,
            client: makeClient(getCredentials: {
                reads.update { $0 += 1 }
                return nil
            })
        )

        store.restore()

        XCTAssertEqual(store.account, account)
        XCTAssertEqual(reads.read { $0 }, 0)
    }

    func testRestoreRebuildsAccountFromLegacyCredentialsOrSignsOut() throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let credentials = makeCredentials()
        let store = makeStore(
            preferences: preferences,
            client: makeClient(getCredentials: { credentials })
        )

        store.restore()

        XCTAssertEqual(store.account?.primaryUrl, credentials.serverUrl)
        XCTAssertEqual(store.account?.fallbackUrl, credentials.fallbackUrl)
        XCTAssertEqual(store.account?.activeUrl, credentials.serverUrl)
        XCTAssertNotNil(
            preferences.getJSON(SessionStore.accountStorageKey, as: ServerAccount.self)
        )

        let emptyDatabase = try TemporaryDatabase()
        let emptyPreferences = PreferencesService(db: emptyDatabase.manager.dbPool)
        let empty = makeStore(preferences: emptyPreferences, client: makeClient())
        empty.restore()
        XCTAssertEqual(empty.state, .signedOut)
    }

    func testSignInNormalizesAndStoresFallbackResult() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let loginArguments = LockedTestBox<[String]>([])
        let stored = LockedTestBox<ServerCredentials?>(nil)
        let client = makeClient(
            storeCredentials: { credentials in
                stored.update { $0 = credentials }
            },
            login: { primary, fallback, username, password in
                loginArguments.update {
                    $0 = [primary, fallback ?? "", username, password]
                }
                return LoginResult(
                    success: true,
                    authType: "token",
                    protocolVersion: "1.16.1",
                    serverType: "navidrome",
                    activeUrl: fallback,
                    activeServerType: "fallback",
                    password: "hashed"
                )
            }
        )
        let store = makeStore(preferences: preferences, client: client)

        try await store.signIn(
            serverUrl: " https://primary.test/// ",
            fallbackUrl: " https://fallback.test/ ",
            username: "alice",
            password: "secret"
        )

        XCTAssertEqual(
            loginArguments.read { $0 },
            ["https://primary.test", "https://fallback.test", "alice", "secret"]
        )
        XCTAssertEqual(store.account?.activeUrl, "https://fallback.test")
        XCTAssertTrue(store.isUsingFallback)
        XCTAssertEqual(stored.read { $0 }?.password, "hashed")
        XCTAssertEqual(stored.read { $0 }?.fallbackUrl, "https://fallback.test")
    }

    func testSignInMapsAuthenticationAndConnectivityFailures() async throws {
        for (error, expected) in [
            ("auth_failed", SubsonicAPIError.authenticationFailed(message: "Authentication failed")),
            ("network_unreachable", SubsonicAPIError.offline),
        ] {
            let database = try TemporaryDatabase()
            let preferences = PreferencesService(db: database.manager.dbPool)
            let store = makeStore(
                preferences: preferences,
                client: makeClient(login: { _, _, _, _ in
                    LoginResult(success: false, error: error)
                })
            )

            do {
                try await store.signIn(
                    serverUrl: "https://server.test",
                    fallbackUrl: nil,
                    username: "alice",
                    password: "wrong"
                )
                XCTFail("Expected sign-in to fail")
            } catch let actual as SubsonicAPIError {
                XCTAssertEqual(actual, expected)
            }
            XCTAssertEqual(store.state, .signedOut)
        }
    }

    func testCompatibilityProbeDistinguishesUnknownAndFallbackOverride() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let store = makeStore(
            preferences: preferences,
            client: makeClient(probeCompatibility: { url, _, _ in
                url.contains("old") ? .incompatible : .unknown
            })
        )

        let primary = await store.compatibility(
            serverUrl: "https://old.test",
            username: "alice",
            password: "secret"
        )
        let fallback = await store.compatibility(
            serverUrl: "https://offline.test",
            username: "alice",
            password: "secret"
        )

        XCTAssertEqual(primary, .incompatible)
        XCTAssertEqual(fallback, .unknown)
        XCTAssertTrue(ServerCompatibility.requiresOverride(
            primary: .incompatible,
            fallback: .compatible
        ))
        XCTAssertFalse(ServerCompatibility.requiresOverride(
            primary: .unknown,
            fallback: .compatible
        ))
        XCTAssertTrue(ServerCompatibility.requiresOverride(
            primary: .unknown,
            fallback: .incompatible
        ))
    }

    func testUpdateURLsUsesFallbackAndKeepsAccountOnFailure() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        let original = makeAccount()
        try preferences.setJSON(original, for: SessionStore.accountStorageKey)
        let credentials = makeCredentials()
        let stored = LockedTestBox<ServerCredentials?>(nil)
        let infoCredentials = LockedTestBox<ServerCredentials?>(nil)
        let client = makeClient(
            getCredentials: { credentials },
            storeCredentials: { credentials in
                stored.update { $0 = credentials }
            },
            ping: { url, _, _, _ in
                (url.contains("fallback"), url.contains("fallback") ? nil : "network_unreachable")
            },
            queryAuthenticatedServerInfo: { _, credentials in
                infoCredentials.update { $0 = credentials }
                return ("1.14.0", "airsonic")
            }
        )
        let store = makeStore(preferences: preferences, client: client)
        store.restore()

        try await store.updateServerUrls(
            primaryUrl: " https://new.test/ ",
            fallbackUrl: "https://fallback.test///"
        )

        XCTAssertEqual(store.account?.primaryUrl, "https://new.test")
        XCTAssertEqual(store.account?.activeUrl, "https://fallback.test")
        XCTAssertEqual(store.account?.serverType, "airsonic")
        XCTAssertEqual(store.account?.protocolVersion, "1.14.0")
        XCTAssertEqual(stored.read { $0 }?.serverUrl, "https://fallback.test")
        XCTAssertEqual(infoCredentials.read { $0 }?.protocolVersion, "1.16.1")

        let successful = store.account
        let failingClient = makeClient(
            getCredentials: { credentials },
            ping: { _, _, _, _ in (false, "network_unreachable") }
        )
        let failing = makeStore(preferences: preferences, client: failingClient)
        failing.restore()
        do {
            try await failing.updateServerUrls(
                primaryUrl: "https://unreachable.test",
                fallbackUrl: nil
            )
            XCTFail("Expected update to fail")
        } catch let error as SubsonicAPIError {
            XCTAssertEqual(error, .offline)
        }
        XCTAssertEqual(failing.account, successful)
    }

    func testRefreshServerInfoAndSignOut() async throws {
        let database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        try preferences.setJSON(makeAccount(), for: SessionStore.accountStorageKey)
        let api = FakeSubsonicAPI()
        api.userHandler = { SubsonicUser(username: $0, streamRole: true) }
        let info = ServerInfo(type: "navidrome", protocolVersion: "1.16.1")
        api.pingHandler = { info }
        let cleared = LockedTestBox(false)
        let store = makeStore(
            preferences: preferences,
            api: api,
            client: makeClient(clearCredentials: { cleared.update { $0 = true } })
        )
        store.restore()

        await store.refreshUser()
        XCTAssertEqual(store.user?.username, "alice")
        let serverInfo = await store.serverInfo()
        XCTAssertEqual(serverInfo, info)

        api.userHandler = { _ in throw SubsonicAPIError.offline }
        await store.refreshUser()
        XCTAssertEqual(store.user?.username, "alice")

        store.signOut()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.user)
        XCTAssertTrue(cleared.read { $0 })
        XCTAssertNil(preferences.getString(SessionStore.accountStorageKey))
    }

    private func makeStore(
        preferences: PreferencesService,
        api: FakeSubsonicAPI = FakeSubsonicAPI(),
        client: SessionAuthenticationClient
    ) -> SessionStore {
        SessionStore(
            authenticationClient: client,
            preferences: preferences,
            api: api
        )
    }

    private func makeClient(
        getCredentials: @escaping () -> ServerCredentials? = { nil },
        storeCredentials: @escaping (ServerCredentials) throws -> Void = { _ in },
        clearCredentials: @escaping () -> Void = {},
        login: @escaping (String, String?, String, String) async -> LoginResult = {
            _, _, _, _ in LoginResult(success: false, error: "network_unreachable")
        },
        ping: @escaping (String, String, String, String) async -> (
            reachable: Bool,
            error: String?
        ) = { _, _, _, _ in (false, "network_unreachable") },
        queryServerInfo: @escaping (String) async -> (
            protocolVersion: String,
            serverType: String
        ) = { _ in ("1.16.0", "subsonic") },
        queryAuthenticatedServerInfo: @escaping (
            String,
            ServerCredentials
        ) async throws -> (
            protocolVersion: String,
            serverType: String
        ) = { _, credentials in
            (credentials.protocolVersion, credentials.serverType)
        },
        probeCompatibility: @escaping (String, String, String) async ->
            ServerCompatibility = { _, _, _ in .compatible }
    ) -> SessionAuthenticationClient {
        SessionAuthenticationClient(
            getCredentials: getCredentials,
            storeCredentials: storeCredentials,
            clearCredentials: clearCredentials,
            login: login,
            ping: ping,
            queryServerInfo: queryServerInfo,
            queryAuthenticatedServerInfo: queryAuthenticatedServerInfo,
            probeCompatibility: probeCompatibility
        )
    }

    private func makeAccount() -> ServerAccount {
        ServerAccount(
            primaryUrl: "https://server.test",
            fallbackUrl: "https://backup.test",
            activeUrl: "https://server.test",
            username: "alice",
            serverType: "navidrome",
            protocolVersion: "1.16.1",
            authType: "token"
        )
    }

    private func makeCredentials() -> ServerCredentials {
        ServerCredentials(
            serverUrl: "https://server.test",
            username: "alice",
            password: "hashed",
            authType: "token",
            protocolVersion: "1.16.1",
            serverType: "navidrome",
            fallbackUrl: "https://backup.test/"
        )
    }
}
