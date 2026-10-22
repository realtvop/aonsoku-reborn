import XCTest
@testable import AonsokuKit

@MainActor
final class AppModelTests: XCTestCase {
    func testActiveSignInRestartsTheNewAccountLifecycle() async throws {
        let fixture = try AppModelFixture(loginSucceeds: true)
        fixture.model.start()
        XCTAssertTrue(fixture.model.isActive)

        try await fixture.model.signIn(
            serverUrl: "https://new.test",
            fallbackUrl: nil,
            username: "bob",
            password: "secret"
        )

        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(fixture.model.session.account?.username, "bob")
        XCTAssertEqual(fixture.model.session.account?.primaryUrl, "https://new.test")
        XCTAssertEqual(fixture.clearedCredentials.read { $0 }, 1)
        fixture.model.signOut()
    }

    func testFailedActiveSignInLeavesTheOldLifecycleStopped() async throws {
        let fixture = try AppModelFixture(loginSucceeds: false)
        fixture.model.start()
        XCTAssertTrue(fixture.model.isActive)

        do {
            try await fixture.model.signIn(
                serverUrl: "https://new.test",
                fallbackUrl: nil,
                username: "bob",
                password: "wrong"
            )
            XCTFail("Expected sign-in to fail")
        } catch let error as SubsonicAPIError {
            XCTAssertEqual(error, .authenticationFailed(message: "Authentication failed"))
        }

        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.model.session.state, .signedOut)
        XCTAssertEqual(fixture.clearedCredentials.read { $0 }, 1)
    }
}

@MainActor
private final class AppModelFixture {
    let model: AppModel
    let clearedCredentials = LockedTestBox(0)
    private let database: TemporaryDatabase

    init(loginSucceeds: Bool) throws {
        database = try TemporaryDatabase()
        let preferences = PreferencesService(db: database.manager.dbPool)
        try preferences.setJSON(
            ServerAccount(
                primaryUrl: "https://old.test",
                activeUrl: "https://old.test",
                username: "alice",
                serverType: "navidrome",
                protocolVersion: "1.16.1",
                authType: "token"
            ),
            for: SessionStore.accountStorageKey
        )
        let coordination = CoordinationService(
            tokenStore: EmptyCoordinationTokenStore(),
            credentials: { nil }
        )
        let services = AppServices(
            audio: AudioService(databaseManager: database.manager),
            library: LibraryService(dbManager: database.manager),
            preferences: preferences,
            coordination: coordination
        )
        let api = FakeSubsonicAPI()
        api.starredHandler = { SearchResults() }
        let clearedCredentials = clearedCredentials
        let client = SessionAuthenticationClient(
            getCredentials: { nil },
            storeCredentials: { _ in },
            clearCredentials: {
                clearedCredentials.update { $0 += 1 }
            },
            login: { primary, _, username, _ in
                guard loginSucceeds else {
                    return LoginResult(success: false, error: "auth_failed")
                }
                return LoginResult(
                    success: true,
                    authType: "token",
                    protocolVersion: "1.16.1",
                    serverType: "navidrome",
                    activeUrl: primary,
                    activeServerType: "primary",
                    password: "stored-password"
                )
            },
            ping: { _, _, _, _ in (false, "network_unreachable") },
            queryServerInfo: { _ in ("1.16.1", "navidrome") },
            queryAuthenticatedServerInfo: { _, credentials in
                (credentials.protocolVersion, credentials.serverType)
            },
            probeCompatibility: { _, _, _ in .compatible }
        )
        model = AppModel(
            services: services,
            bundle: .main,
            network: NetworkMonitor(isOnline: false, isMetered: false),
            api: api,
            sessionAuthenticationClient: client
        )
    }
}

private final class EmptyCoordinationTokenStore: CoordinationTokenStoring,
    @unchecked Sendable {
    func loadTokens() -> CoordinationTokens? { nil }
    func saveTokens(_: CoordinationTokens) {}
    func replaceTokens(
        _: CoordinationTokens,
        ifCurrentMatches _: CoordinationTokens
    ) -> Bool { false }
    func clearTokens() {}
    func clearTokens(ifCurrentMatches _: CoordinationTokens) -> Bool { false }
    func loadConfig() -> CoordinationConfig? { nil }
    func saveConfig(_: CoordinationConfig) {}
}
