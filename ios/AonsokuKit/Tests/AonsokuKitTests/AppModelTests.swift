import XCTest
@testable import AonsokuKit

@MainActor
final class AppModelTests: XCTestCase {
    private let alice = LibraryAccountIdentity(
        serverUrl: "https://old.test",
        username: "alice"
    )

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

        // The old account's lifecycle is stopped; bob starts once the user
        // has decided about alice's library.
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertTrue(fixture.model.isAwaitingAccountDecision)
        try fixture.model.confirmAccountSwitch()

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

    // MARK: Account switch confirmation

    func testSigningInAsAnotherUserWaitsForTheUserAndErasesNothing() async throws {
        let download = try makeDownload()
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        XCTAssertTrue(fixture.model.isActive)

        try await fixture.signInAsBob()

        let request = try XCTUnwrap(fixture.model.pendingAccountSwitch)
        XCTAssertEqual(
            request.reason,
            .differentAccount(previousServer: "https://old.test", previousUsername: "alice")
        )
        XCTAssertEqual(request.serverUrl, "https://new.test")
        XCTAssertEqual(request.username, "bob")
        XCTAssertTrue(fixture.model.isAwaitingAccountDecision)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.model.session.account?.username, "bob")
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertEqual(fixture.pendingMarker?.request, request)
    }

    func testConfirmingErasesTheOldDataRecordsTheOwnerAndActivates() async throws {
        let download = try makeDownload()
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()
        XCTAssertTrue(fixture.model.isAwaitingAccountDecision)

        try fixture.model.confirmAccountSwitch()

        XCTAssertNil(fixture.model.pendingAccountSwitch)
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(
            fixture.libraryOwner,
            LibraryAccountIdentity(serverUrl: "https://new.test", username: "bob")
        )
        XCTAssertFalse(fixture.hasLibraryData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        XCTAssertNil(fixture.pendingMarker)
        fixture.model.signOut()
    }

    func testCancellingSignsTheNewSessionOutAndErasesNothing() async throws {
        let download = try makeDownload()
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()

        fixture.model.cancelAccountSwitch()

        XCTAssertNil(fixture.model.pendingAccountSwitch)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.model.session.state, .signedOut)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertNil(fixture.pendingMarker)
    }

    func testKeepingTheLibraryOfAnUnknownOwnerRecordsItAndKeepsTheData() async throws {
        let download = try makeDownload()
        let fixture = try AppModelFixture(account: nil, owner: nil, libraryData: true)
        fixture.model.start()
        XCTAssertEqual(fixture.model.session.state, .signedOut)

        try await fixture.model.signIn(
            serverUrl: "https://old.test",
            fallbackUrl: nil,
            username: "alice",
            password: "secret"
        )

        XCTAssertEqual(fixture.model.pendingAccountSwitch?.reason, .unknownOwner)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertNil(fixture.libraryOwner)

        try fixture.model.keepLibraryData()

        XCTAssertNil(fixture.model.pendingAccountSwitch)
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertNil(fixture.pendingMarker)
        fixture.model.signOut()
    }

    func testRestoringWithoutAnOwnerAdoptsTheLibrarySilently() throws {
        let fixture = try AppModelFixture(owner: nil, libraryData: true)

        fixture.model.start()

        XCTAssertTrue(fixture.model.isActive)
        XCTAssertFalse(fixture.model.isAwaitingAccountDecision)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)
        fixture.model.signOut()
    }

    func testSameUsernameAtAnotherServerKeepsTheLibraryAndLaterLaunchesAdoptIt() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()

        try await fixture.model.signIn(
            serverUrl: "https://new.test",
            fallbackUrl: nil,
            username: "Alice",
            password: "secret"
        )

        XCTAssertEqual(
            fixture.model.pendingAccountSwitch?.reason,
            .differentServer(previousServer: "https://old.test")
        )
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.libraryOwner, alice)

        try fixture.model.keepLibraryData()

        let moved = LibraryAccountIdentity(serverUrl: "https://new.test", username: "Alice")
        XCTAssertEqual(fixture.libraryOwner, moved)
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertTrue(fixture.hasLibraryData)

        let relaunched = fixture.relaunch()
        relaunched.start()

        XCTAssertTrue(relaunched.isActive)
        XCTAssertFalse(relaunched.isAwaitingAccountDecision)
        XCTAssertEqual(fixture.libraryOwner, moved)
        XCTAssertTrue(fixture.hasLibraryData)
        relaunched.signOut()
    }

    func testKeepingAnotherUsersLibraryIsRefusedAndChangesNothing() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()
        let request = try XCTUnwrap(fixture.model.pendingAccountSwitch)

        XCTAssertThrowsError(try fixture.model.keepLibraryData()) {
            XCTAssertEqual($0 as? AccountSwitchError, .libraryBelongsToAnotherAccount)
        }

        XCTAssertEqual(fixture.model.pendingAccountSwitch, request)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertEqual(fixture.pendingMarker?.request, request)
    }

    func testRelaunchWhilePendingAsksAgainAndCanStillBeResolved() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()
        let request = try XCTUnwrap(fixture.model.pendingAccountSwitch)

        let relaunched = fixture.relaunch()
        relaunched.start()

        XCTAssertEqual(relaunched.pendingAccountSwitch, request)
        XCTAssertFalse(relaunched.isActive)
        XCTAssertEqual(relaunched.session.account?.username, "bob")
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)

        try relaunched.confirmAccountSwitch()

        XCTAssertTrue(relaunched.isActive)
        XCTAssertFalse(fixture.hasLibraryData)
        XCTAssertNil(fixture.pendingMarker)
        relaunched.signOut()
    }

    func testStalePendingMarkersAreRemovedAtLaunch() throws {
        let other = PendingAccountSwitchRecord(AccountSwitchRequest(
            reason: .unknownOwner,
            serverUrl: "https://new.test",
            username: "bob"
        ))
        let forOwner = PendingAccountSwitchRecord(AccountSwitchRequest(
            reason: .unknownOwner,
            serverUrl: "https://old.test",
            username: "alice"
        ))

        // A marker for an account that is not the restored one.
        let mismatched = try AppModelFixture(
            owner: alice,
            libraryData: true,
            pendingMarker: other
        )
        mismatched.model.start()
        XCTAssertTrue(mismatched.model.isActive)
        XCTAssertFalse(mismatched.model.isAwaitingAccountDecision)
        XCTAssertNil(mismatched.pendingMarker)
        mismatched.model.signOut()

        // A marker whose owner has been recorded since.
        let resolved = try AppModelFixture(
            owner: alice,
            libraryData: true,
            pendingMarker: forOwner
        )
        resolved.model.start()
        XCTAssertTrue(resolved.model.isActive)
        XCTAssertNil(resolved.pendingMarker)
        resolved.model.signOut()

        // A marker without any signed-in account.
        let signedOut = try AppModelFixture(
            account: nil,
            owner: alice,
            libraryData: true,
            pendingMarker: other
        )
        signedOut.model.start()
        XCTAssertFalse(signedOut.model.isAwaitingAccountDecision)
        XCTAssertNil(signedOut.pendingMarker)
    }

    func testSigningOutClearsThePendingRequest() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()
        XCTAssertNotNil(fixture.pendingMarker)

        fixture.model.signOut()

        XCTAssertNil(fixture.model.pendingAccountSwitch)
        XCTAssertFalse(fixture.model.isAwaitingAccountDecision)
        XCTAssertNil(fixture.pendingMarker)
        XCTAssertEqual(fixture.model.session.state, .signedOut)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)

        let relaunched = fixture.relaunch()
        relaunched.start()
        XCTAssertEqual(relaunched.session.state, .signedOut)
        XCTAssertFalse(relaunched.isAwaitingAccountDecision)
    }

    func testSigningInAgainReplacesAPendingRequest() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()
        let first = try XCTUnwrap(fixture.model.pendingAccountSwitch)

        try await fixture.model.signIn(
            serverUrl: "https://third.test",
            fallbackUrl: nil,
            username: "carol",
            password: "secret"
        )

        let second = try XCTUnwrap(fixture.model.pendingAccountSwitch)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.username, "carol")
        XCTAssertEqual(fixture.pendingMarker?.request, second)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertTrue(fixture.hasLibraryData)
    }

    func testAFailedEraseKeepsTheRequestPendingAndCanBeRetried() async throws {
        let locked = try makeUndeletableDownload()
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        try await fixture.signInAsBob()
        let request = try XCTUnwrap(fixture.model.pendingAccountSwitch)

        XCTAssertThrowsError(try fixture.model.confirmAccountSwitch())

        XCTAssertEqual(fixture.model.pendingAccountSwitch, request)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertEqual(fixture.pendingMarker?.request, request)

        locked.unlock()
        try fixture.model.confirmAccountSwitch()

        XCTAssertNil(fixture.model.pendingAccountSwitch)
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(
            fixture.libraryOwner,
            LibraryAccountIdentity(serverUrl: "https://new.test", username: "bob")
        )
        XCTAssertNil(fixture.pendingMarker)
        fixture.model.signOut()
    }

    func testResolvingWithoutARequestDoesNothing() throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()
        XCTAssertTrue(fixture.model.isActive)

        try fixture.model.confirmAccountSwitch()
        try fixture.model.keepLibraryData()
        fixture.model.cancelAccountSwitch()

        XCTAssertTrue(fixture.model.isActive)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertEqual(fixture.model.session.account?.username, "alice")
        fixture.model.signOut()
    }

    // MARK: Changing the server address

    func testChangingTheServerAddressKeepsTheLibraryAcrossARelaunch() async throws {
        let download = try makeDownload()
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.reachableServers.update { $0 = ["https://new.test"] }
        fixture.model.start()
        XCTAssertTrue(fixture.model.isActive)

        try await fixture.model.updateServerUrls(
            primaryUrl: "https://new.test",
            fallbackUrl: "https://backup.test"
        )

        let moved = LibraryAccountIdentity(serverUrl: "https://new.test", username: "alice")
        XCTAssertEqual(fixture.model.session.account?.primaryUrl, "https://new.test")
        XCTAssertEqual(fixture.libraryOwner, moved)

        let relaunched = fixture.relaunch()
        relaunched.start()

        XCTAssertEqual(relaunched.session.account?.primaryUrl, "https://new.test")
        XCTAssertTrue(relaunched.isActive)
        XCTAssertFalse(relaunched.isAwaitingAccountDecision)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        relaunched.signOut()
    }

    func testAddressChangeOutsideAppModelMakesTheNextLaunchAskInsteadOfErasing() async throws {
        let download = try makeDownload()
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.reachableServers.update { $0 = ["https://new.test"] }
        fixture.model.start()

        // Data written by an older build: the account moved, the owner did not.
        try await fixture.model.session.updateServerUrls(
            primaryUrl: "https://new.test",
            fallbackUrl: nil
        )
        XCTAssertEqual(fixture.libraryOwner, alice)

        let relaunched = fixture.relaunch()
        relaunched.start()

        XCTAssertEqual(
            relaunched.pendingAccountSwitch?.reason,
            .differentServer(previousServer: "https://old.test")
        )
        XCTAssertFalse(relaunched.isActive)
        XCTAssertTrue(fixture.hasLibraryData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path))
        XCTAssertEqual(fixture.libraryOwner, alice)
    }

    func testFailedAddressChangeRethrowsAndLeavesTheOwnerAlone() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.model.start()

        do {
            try await fixture.model.updateServerUrls(
                primaryUrl: "https://new.test",
                fallbackUrl: nil
            )
            XCTFail("Expected the address change to fail")
        } catch let error as SubsonicAPIError {
            XCTAssertEqual(error, .offline)
        }

        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertEqual(fixture.model.session.account?.primaryUrl, "https://old.test")
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertTrue(fixture.hasLibraryData)
        fixture.model.signOut()
    }

    func testAddressChangeDoesNotClaimALibraryRecordedForAnotherAccount() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.reachableServers.update { $0 = ["https://new.test"] }
        fixture.model.start()
        let carol = LibraryAccountIdentity(serverUrl: "https://elsewhere.test", username: "carol")
        try fixture.preferences.setJSON(carol, for: AppModel.libraryOwnerStorageKey)

        try await fixture.model.updateServerUrls(primaryUrl: "https://new.test", fallbackUrl: nil)

        XCTAssertEqual(fixture.model.session.account?.primaryUrl, "https://new.test")
        XCTAssertEqual(fixture.libraryOwner, carol)
        fixture.model.signOut()
    }

    func testAddressCannotChangeWhileADecisionIsPending() async throws {
        let fixture = try AppModelFixture(owner: alice, libraryData: true)
        fixture.reachableServers.update { $0 = ["https://new.test", "https://other.test"] }
        fixture.model.start()
        try await fixture.signInAsBob()
        let request = try XCTUnwrap(fixture.model.pendingAccountSwitch)

        do {
            try await fixture.model.updateServerUrls(
                primaryUrl: "https://other.test",
                fallbackUrl: nil
            )
            XCTFail("Expected the address change to be refused")
        } catch let error as AccountSwitchError {
            XCTAssertEqual(error, .decisionPending)
        }

        XCTAssertEqual(fixture.model.pendingAccountSwitch, request)
        XCTAssertEqual(fixture.model.session.account?.primaryUrl, "https://new.test")
    }

    // MARK: Helpers

    /// A downloaded file in the audio cache, removed when the test ends.
    private func makeDownload() throws -> URL {
        let directory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let file = directory.appendingPathComponent("account-switch-\(UUID().uuidString).mp3")
        try Data([1, 2, 3]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    /// A folder in the audio cache that cannot be deleted until `unlock()`,
    /// so erasing the downloads fails.
    private func makeUndeletableDownload() throws -> (unlock: () -> Void, url: URL) {
        let directory = try AudioCacheUtils.cacheDirectoryURL(createIfNeeded: true)
        let folder = directory.appendingPathComponent(
            "account-switch-locked-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("song.mp3")
        try Data([1, 2, 3]).write(to: file)
        let unlock: () -> Void = {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: folder.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: folder.path
        )
        addTeardownBlock {
            unlock()
            try? FileManager.default.removeItem(at: folder)
        }
        guard !FileManager.default.isDeletableFile(atPath: file.path) else {
            throw XCTSkip("File permissions are not enforced for this process.")
        }
        return (unlock, folder)
    }
}

@MainActor
private final class AppModelFixture {
    static let aliceAccount = ServerAccount(
        primaryUrl: "https://old.test",
        activeUrl: "https://old.test",
        username: "alice",
        serverType: "navidrome",
        protocolVersion: "1.16.1",
        authType: "token"
    )

    private(set) var model: AppModel
    let preferences: PreferencesService
    let services: AppServices
    let clearedCredentials = LockedTestBox(0)
    /// Server addresses that answer the credentials check of a changed address.
    let reachableServers = LockedTestBox<Set<String>>([])
    private let api: FakeSubsonicAPI
    private let client: SessionAuthenticationClient
    private let database: TemporaryDatabase

    /// `account` is the signed-in account at launch, `owner` the recorded
    /// library owner and `libraryData` whether a synced library exists.
    init(
        loginSucceeds: Bool = true,
        account: ServerAccount? = AppModelFixture.aliceAccount,
        owner: LibraryAccountIdentity? = nil,
        libraryData: Bool = false,
        pendingMarker: PendingAccountSwitchRecord? = nil
    ) throws {
        database = try TemporaryDatabase()
        preferences = PreferencesService(db: database.manager.dbPool)
        let credentials = LockedTestBox<ServerCredentials?>(nil)
        if let account {
            try preferences.setJSON(account, for: SessionStore.accountStorageKey)
            credentials.update {
                $0 = ServerCredentials(
                    serverUrl: account.activeUrl,
                    username: account.username,
                    password: "stored-password",
                    authType: account.authType,
                    protocolVersion: account.protocolVersion,
                    serverType: account.serverType,
                    fallbackUrl: account.fallbackUrl
                )
            }
        }
        if let owner {
            try preferences.setJSON(owner, for: AppModel.libraryOwnerStorageKey)
        }
        if let pendingMarker {
            try preferences.setJSON(
                pendingMarker,
                for: AppModel.pendingAccountSwitchStorageKey
            )
        }
        if libraryData {
            try SongRepository(db: database.manager.dbPool).upsert(makeSongRecord("old"))
            try SyncStateRepository(db: database.manager.dbPool).recordFullSync()
        }
        let coordination = CoordinationService(
            tokenStore: EmptyCoordinationTokenStore(),
            credentials: { nil }
        )
        services = AppServices(
            audio: AudioService(
                databaseManager: database.manager,
                scrobbleBuffer: makeIsolatedScrobbleBuffer(),
                scrobbleSubmitter: makeIsolatedScrobbleSubmitter()
            ),
            library: LibraryService(dbManager: database.manager),
            preferences: preferences,
            coordination: coordination
        )
        api = FakeSubsonicAPI()
        api.starredHandler = { SearchResults() }
        let clearedCredentials = clearedCredentials
        let reachableServers = reachableServers
        client = SessionAuthenticationClient(
            getCredentials: { credentials.read { $0 } },
            storeCredentials: { stored in
                credentials.update { $0 = stored }
            },
            clearCredentials: {
                clearedCredentials.update { $0 += 1 }
                credentials.update { $0 = nil }
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
            ping: { url, _, _, _ in
                let reachable = reachableServers.read { $0.contains(url) }
                return (reachable, reachable ? nil : "network_unreachable")
            },
            queryServerInfo: { _ in ("1.16.1", "navidrome") },
            queryAuthenticatedServerInfo: { _, credentials in
                (credentials.protocolVersion, credentials.serverType)
            },
            probeCompatibility: { _, _, _ in .compatible }
        )
        model = Self.makeModel(services: services, api: api, client: client)
    }

    /// A new app model over the same stored state, as after a relaunch.
    func relaunch() -> AppModel {
        model = Self.makeModel(services: services, api: api, client: client)
        return model
    }

    func signInAsBob() async throws {
        try await model.signIn(
            serverUrl: "https://new.test",
            fallbackUrl: nil,
            username: "bob",
            password: "secret"
        )
    }

    var libraryOwner: LibraryAccountIdentity? {
        preferences.getJSON(AppModel.libraryOwnerStorageKey, as: LibraryAccountIdentity.self)
    }

    var pendingMarker: PendingAccountSwitchRecord? {
        preferences.getJSON(
            AppModel.pendingAccountSwitchStorageKey,
            as: PendingAccountSwitchRecord.self
        )
    }

    /// Whether the synced songs of the library are still on the device.
    var hasLibraryData: Bool {
        guard let songs = try? services.library.songs().items else { return false }
        return !songs.isEmpty && services.library.availability().available
    }

    private static func makeModel(
        services: AppServices,
        api: FakeSubsonicAPI,
        client: SessionAuthenticationClient
    ) -> AppModel {
        AppModel(
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
