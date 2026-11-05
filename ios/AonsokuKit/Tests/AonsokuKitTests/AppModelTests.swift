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
            username: "alice",
            password: "secret"
        )

        XCTAssertEqual(
            fixture.model.pendingAccountSwitch?.reason,
            .differentServer(previousServer: "https://old.test")
        )
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.libraryOwner, alice)

        try fixture.model.keepLibraryData()

        let moved = LibraryAccountIdentity(serverUrl: "https://new.test", username: "alice")
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

    func testChangingTheServerAddressRequiresARecordedDecisionBeforeUsingTheLibrary() async throws {
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
        XCTAssertEqual(fixture.libraryOwner, alice)
        XCTAssertFalse(fixture.model.isActive)
        XCTAssertEqual(fixture.model.pendingAccountSwitch?.reason, .differentServer(previousServer: "https://old.test"))
        let waiting = fixture.relaunch()
        waiting.start()
        XCTAssertTrue(waiting.isAwaitingAccountDecision)
        XCTAssertFalse(waiting.isActive)
        try waiting.keepLibraryData()
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

    // MARK: Sleep, wake and network changes

    func testSleepAndWakeReachTheLifecycleOfARunningApp() async throws {
        let power = ManualPowerEvents()
        let recorder = LifecycleRecorder()
        let fixture = try AppModelFixture(
            owner: alice,
            powerEvents: power,
            lifecycle: recorder.makeLifecycle()
        )
        fixture.model.start()
        fixture.services.lifecycle.didFinishLaunching()
        recorder.clear()

        power.send(.willSleep)
        let slept = await waitForPlayerStoreTest { recorder.calls == ["sleep"] }
        XCTAssertTrue(slept)

        power.send(.didWake)
        let woke = await waitForPlayerStoreTest { recorder.calls == ["sleep", "connection"] }
        XCTAssertTrue(woke)
        fixture.model.signOut()
    }

    func testWakeAndPathChangesResumeTheLibrarySync() async throws {
        let power = ManualPowerEvents()
        let recorder = LifecycleRecorder()
        let fixture = try AppModelFixture(
            owner: alice,
            powerEvents: power,
            reconnectsOnNetworkPathChange: true,
            lifecycle: recorder.makeLifecycle()
        )
        fixture.model.start()
        fixture.services.lifecycle.didFinishLaunching()
        recorder.clear()
        XCTAssertTrue(fixture.model.isActive)
        XCTAssertEqual(fixture.model.sync.phase, .idle, "offline: no startup sync")

        // Woken without a connection: nothing can be resumed yet.
        power.send(.didWake)
        let wokeOffline = await waitForPlayerStoreTest { recorder.calls == ["connection"] }
        XCTAssertTrue(wokeOffline)
        XCTAssertEqual(fixture.model.sync.phase, .idle)

        // Woken with one: the sync the startup could not run is started now.
        // (The library has no credentials, so it ends in a failure at once.)
        fixture.setOnline(true)
        power.send(.didWake)
        func syncFailed() -> Bool {
            if case .failed = fixture.model.sync.phase { return true }
            return false
        }
        let failed = await waitForPlayerStoreTest { syncFailed() }
        XCTAssertTrue(failed, "\(fixture.model.sync.phase)")

        // A change of network path then runs it again without waiting.
        fixture.network.publish(
            NetworkPathState(
                isOnline: true,
                isExpensive: false,
                isConstrained: false,
                interfaces: [.wifi]
            ),
            mayHaveBrokenConnections: true
        )
        XCTAssertEqual(fixture.model.sync.phase, .waitingForConnection)
        fixture.model.signOut()
    }

    func testWakeWhileSignedOutOnlyReachesTheLifecycle() async throws {
        let power = ManualPowerEvents()
        let recorder = LifecycleRecorder()
        let fixture = try AppModelFixture(
            account: nil,
            owner: nil,
            powerEvents: power,
            lifecycle: recorder.makeLifecycle()
        )
        fixture.setOnline(true)
        fixture.model.start()
        fixture.services.lifecycle.didFinishLaunching()
        recorder.clear()
        XCTAssertFalse(fixture.model.isActive)

        power.send(.didWake)
        let woke = await waitForPlayerStoreTest { recorder.calls == ["connection"] }
        XCTAssertTrue(woke)
        XCTAssertEqual(fixture.model.sync.phase, .idle)
    }

    func testNetworkPathChangesCheckConnectionsOnlyWhereThePlatformWantsIt() throws {
        let path = NetworkPathState(
            isOnline: true,
            isExpensive: false,
            isConstrained: false,
            interfaces: [.wifi]
        )

        let wanted = LifecycleRecorder()
        let reconnecting = try AppModelFixture(
            owner: alice,
            reconnectsOnNetworkPathChange: true,
            lifecycle: wanted.makeLifecycle()
        )
        reconnecting.model.start()
        reconnecting.services.lifecycle.didFinishLaunching()
        wanted.clear()
        reconnecting.network.publish(path, mayHaveBrokenConnections: false)
        XCTAssertEqual(wanted.calls, [])
        reconnecting.network.publish(path, mayHaveBrokenConnections: true)
        XCTAssertEqual(wanted.calls, ["connection"])
        reconnecting.model.signOut()

        // iOS suspends the app and checks on its return to the foreground.
        let unwanted = LifecycleRecorder()
        let suspended = try AppModelFixture(
            owner: alice,
            reconnectsOnNetworkPathChange: false,
            lifecycle: unwanted.makeLifecycle()
        )
        suspended.model.start()
        suspended.services.lifecycle.didFinishLaunching()
        unwanted.clear()
        XCTAssertNil(suspended.network.onPathChange)
        suspended.network.publish(path, mayHaveBrokenConnections: true)
        XCTAssertEqual(unwanted.calls, [])
        suspended.model.signOut()
    }

    func testPowerObservationStartsOnceAndEndsWithTheModel() async throws {
        let power = ManualPowerEvents()
        let recorder = LifecycleRecorder()
        let fixture = try AppModelFixture(
            owner: alice,
            powerEvents: power,
            lifecycle: recorder.makeLifecycle()
        )
        XCTAssertEqual(power.observerCount, 0, "nothing is observed before the model starts")

        fixture.model.start()
        fixture.model.start()
        XCTAssertEqual(power.observeCalls, 1)
        XCTAssertEqual(power.observerCount, 1)

        fixture.services.lifecycle.didFinishLaunching()
        recorder.clear()
        power.send(.didWake)
        let woke = await waitForPlayerStoreTest { recorder.calls == ["connection"] }
        XCTAssertTrue(woke)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.calls, ["connection"], "one wake is one report")

        // Signing out keeps the model, and so the observation, alive.
        fixture.model.signOut()
        XCTAssertEqual(power.observerCount, 1)

        weak var released: AppModel? = fixture.model
        _ = fixture.relaunch()
        XCTAssertNil(released)
        XCTAssertEqual(power.observerCount, 0)
        recorder.clear()
        power.send(.didWake)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.calls, [])
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
    nonisolated static let aliceAccount = ServerAccount(
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
    /// Offline, with connectivity that `setOnline` can change.
    let network = NetworkMonitor(isOnline: false, isMetered: false)
    let clearedCredentials = LockedTestBox(0)
    /// Server addresses that answer the credentials check of a changed address.
    let reachableServers = LockedTestBox<Set<String>>([])
    private let api: FakeSubsonicAPI
    private let client: SessionAuthenticationClient
    private let database: TemporaryDatabase
    private let powerEvents: any SystemPowerEventSource
    private let reconnectsOnNetworkPathChange: Bool

    /// `account` is the signed-in account at launch, `owner` the recorded
    /// library owner and `libraryData` whether a synced library exists.
    /// `powerEvents` and `reconnectsOnNetworkPathChange` replace the
    /// platform's, and `lifecycle` the service that receives what the model
    /// forwards.
    init(
        loginSucceeds: Bool = true,
        account: ServerAccount? = AppModelFixture.aliceAccount,
        owner: LibraryAccountIdentity? = nil,
        libraryData: Bool = false,
        pendingMarker: PendingAccountSwitchRecord? = nil,
        powerEvents: (any SystemPowerEventSource)? = nil,
        reconnectsOnNetworkPathChange: Bool? = nil,
        lifecycle: AppLifecycleService? = nil
    ) throws {
        self.powerEvents = powerEvents ?? PlatformPower.makeSource()
        self.reconnectsOnNetworkPathChange = reconnectsOnNetworkPathChange
            ?? PlatformPower.reconnectsOnNetworkPathChange
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
            // No credentials, so a sync that a test starts ends at once
            // without reaching any server.
            library: LibraryService(
                dbManager: database.manager,
                credentialsProvider: { nil }
            ),
            preferences: preferences,
            coordination: coordination,
            lifecycleFactory: { lifecycle ?? AppLifecycleService(audio: $0) }
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
        model = Self.makeModel(
            services: services,
            network: network,
            api: api,
            client: client,
            powerEvents: self.powerEvents,
            reconnectsOnNetworkPathChange: self.reconnectsOnNetworkPathChange
        )
    }

    /// A new app model over the same stored state, as after a relaunch.
    func relaunch() -> AppModel {
        model = Self.makeModel(
            services: services,
            network: network,
            api: api,
            client: client,
            powerEvents: powerEvents,
            reconnectsOnNetworkPathChange: reconnectsOnNetworkPathChange
        )
        return model
    }

    /// Changes what the sync store sees of the connection, which the offline
    /// monitor never updates by itself.
    func setOnline(_ isOnline: Bool, isMetered: Bool = false) {
        (network.connectivity as? LockedConnectivity)?
            .update(isOnline: isOnline, isMetered: isMetered)
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
        network: NetworkMonitor,
        api: FakeSubsonicAPI,
        client: SessionAuthenticationClient,
        powerEvents: any SystemPowerEventSource,
        reconnectsOnNetworkPathChange: Bool
    ) -> AppModel {
        AppModel(
            services: services,
            bundle: .main,
            network: network,
            api: api,
            sessionAuthenticationClient: client,
            powerEvents: powerEvents,
            reconnectsOnNetworkPathChange: reconnectsOnNetworkPathChange
        )
    }
}

/// Reports the events a test sends, to everyone observing.
private final class ManualPowerEvents: SystemPowerEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (SystemPowerEvent) -> Void] = [:]
    private var observations = 0

    /// Observations that have not ended.
    var observerCount: Int { lock.withLock { handlers.count } }
    /// Observations ever begun.
    var observeCalls: Int { lock.withLock { observations } }

    func observe(
        _ handler: @escaping @Sendable (SystemPowerEvent) -> Void
    ) -> ObservationToken {
        let id = UUID()
        lock.withLock {
            handlers[id] = handler
            observations += 1
        }
        return ObservationToken { [weak self] in
            self?.lock.withLock { self?.handlers[id] = nil }
        }
    }

    func send(_ event: SystemPowerEvent) {
        let current = lock.withLock { Array(handlers.values) }
        for handler in current { handler(event) }
    }
}

/// An app lifecycle that records what reaches the audio side, in order.
private final class LifecycleRecorder: @unchecked Sendable {
    private let log = LockedTestBox<[String]>([])

    var calls: [String] { log.read { $0 } }

    func clear() { log.update { $0.removeAll() } }

    func makeLifecycle() -> AppLifecycleService {
        let log = log
        let record: @Sendable (String) -> Void = { name in
            log.update { $0.append(name) }
        }
        return AppLifecycleService(
            audio: AudioLifecycleActions(
                start: { record("start") },
                didEnterBackground: { record("background") },
                willEnterForeground: { record("foreground") },
                willTerminate: { record("terminate") },
                handleBackgroundSession: { _, _ in false },
                willSleep: { record("sleep") },
                connectionMayHaveChanged: { record("connection") }
            ),
            coordination: CoordinationLifecycleActions(
                didEnterBackground: {},
                willEnterForeground: {},
                willTerminate: {}
            )
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
