import Foundation
import XCTest
@testable import AonsokuKit

final class TailscaleSupportTests: XCTestCase {
    func testSupportFollowsWhetherTheRuntimeIsLinked() {
        #if canImport(CTailscale)
        // Linked on iOS; the embedded node itself still needs iOS 18.1.
        if #available(iOS 18.1, *) { XCTAssertTrue(TailscaleSupport.isAvailable) }
        else { XCTAssertFalse(TailscaleSupport.isAvailable) }
        #else
        XCTAssertFalse(TailscaleSupport.isAvailable)
        #endif
    }

    func testThePlatformRuntimeIsTheLinkedOne() {
        #if canImport(CTailscale)
        XCTAssertTrue(TailscaleRuntimes.platform is LibTailscaleRuntime)
        #else
        XCTAssertTrue(TailscaleRuntimes.platform is UnavailableTailscaleRuntime)
        #endif
    }

    func testTheUnavailableRuntimeFailsEveryCall() {
        let runtime = UnavailableTailscaleRuntime()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())

        assertUnavailable { _ = try runtime.open(directory: directory, hostname: "host", authKey: nil) }
        assertUnavailable { try runtime.start(1) }
        assertUnavailable { _ = try runtime.statusJSON(1) }
        assertUnavailable { _ = try runtime.loopback(1) }
        // Closing a handle that was never opened is a no-op, not a failure.
        runtime.close(1)
    }

    func testTheUnavailableErrorSaysWhatIsMissing() {
        XCTAssertEqual(
            TailscaleUnavailableError().errorDescription,
            "Tailscale is not available on this platform."
        )
        XCTAssertEqual(TailscaleUnavailableError(), TailscaleUnavailableError())
    }

    func testRoutingNeverEngagesWithoutARuntime() throws {
        let defaults = try makeDefaults()
        defaults.set(
            Data(#"{"enabled":true,"additionalHosts":["music.internal"]}"#.utf8),
            forKey: "tailscale.configuration.v1"
        )
        let urls = [
            "http://music.internal:4533", "https://nas.example.ts.net",
            "http://100.64.0.1:4533", "ws://192.168.8.10:4533",
        ].compactMap(URL.init(string:))
        XCTAssertEqual(urls.count, 4)

        let withoutRuntime = TailscaleRouting(defaults: defaults, isRuntimeAvailable: false)
        withoutRuntime.updatePeers(["nas.example.ts.net"], subnetRoutes: ["192.168.8.0/24"])
        let withRuntime = TailscaleRouting(defaults: defaults, isRuntimeAvailable: true)
        withRuntime.updatePeers(["nas.example.ts.net"], subnetRoutes: ["192.168.8.0/24"])

        // The saved setting is kept, so it applies again where a runtime exists.
        XCTAssertTrue(withoutRuntime.current.enabled)
        for url in urls {
            XCTAssertFalse(withoutRuntime.shouldRoute(url), "\(url)")
            XCTAssertFalse(withoutRuntime.requiresTailscale(url), "\(url)")
            XCTAssertTrue(withRuntime.shouldRoute(url), "\(url)")
            XCTAssertTrue(withRuntime.requiresTailscale(url), "\(url)")
        }
    }

    func testPublicAddressesAreNeverRoutedWhateverTheRuntime() throws {
        let defaults = try makeDefaults()
        let routing = TailscaleRouting(defaults: defaults, isRuntimeAvailable: true)
        routing.configure(enabled: true, additionalHosts: [])
        let url = try XCTUnwrap(URL(string: "https://music.example.com"))

        XCTAssertFalse(routing.shouldRoute(url))
        XCTAssertFalse(routing.requiresTailscale(url))
    }

    private func assertUnavailable(
        _ call: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try call(), file: file, line: line) { error in
            XCTAssertEqual(error as? TailscaleUnavailableError, TailscaleUnavailableError(), file: file, line: line)
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "tailscale-support-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

@available(iOS 18.1, *)
final class EmbeddedTailscaleNodeTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aonsoku-tailscale-node-tests", isDirectory: true)

    func testNodeDrivesTheRuntimeItWasGiven() async throws {
        let runtime = FakeTailscaleRuntime()
        let node = try EmbeddedTailscaleNode(
            directory: directory, hostname: "aonsoku-test", authKey: "tskey-test", runtime: runtime
        )
        XCTAssertEqual(
            runtime.opens,
            [.init(directory: directory, hostname: "aonsoku-test", authKey: "tskey-test")]
        )

        try await node.start()
        let status = try await node.status()
        let proxy = try await node.loopback()
        await node.stop()

        XCTAssertEqual(runtime.started, [runtime.handle])
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.`Self`?.TailscaleIPs, ["100.64.0.9"])
        XCTAssertEqual(proxy.address, "127.0.0.1:1055")
        XCTAssertEqual(proxy.password, "proxy-secret")
        XCTAssertEqual(proxy.localAPIKey, "api-key")
        XCTAssertEqual(runtime.closed, [runtime.handle])
    }

    func testLoopbackIsFetchedOnceUntilTheNodeStops() async throws {
        let runtime = FakeTailscaleRuntime()
        let node = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)

        _ = try await node.loopback()
        _ = try await node.loopback()

        XCTAssertEqual(runtime.loopbackCalls, 1)
        await node.stop()
    }

    func testAStoppedNodeRejectsFurtherCalls() async throws {
        let runtime = FakeTailscaleRuntime()
        let node = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)
        _ = try await node.loopback()
        await node.stop()

        await assertRejected(.cannotConnectToHost) { try await node.start() }
        await assertRejected(.notConnectedToInternet) { _ = try await node.status() }
        await assertRejected(.notConnectedToInternet) { _ = try await node.loopback() }
        XCTAssertEqual(runtime.started, [])
    }

    func testStoppingTwiceClosesTheHandleOnce() async throws {
        let runtime = FakeTailscaleRuntime()
        let node = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)

        await node.stop()
        await node.stop()

        XCTAssertEqual(runtime.closed, [runtime.handle])
    }

    func testReleasingTheNodeClosesItsHandle() throws {
        let runtime = FakeTailscaleRuntime()
        func openAndDrop() throws {
            _ = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)
        }

        try openAndDrop()

        XCTAssertEqual(runtime.closed, [runtime.handle])
    }

    func testAStoppedNodeIsNotClosedAgainWhenItIsReleased() async throws {
        let runtime = FakeTailscaleRuntime()
        func openAndStop() async throws {
            let node = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)
            await node.stop()
        }

        try await openAndStop()

        XCTAssertEqual(runtime.closed, [runtime.handle])
    }

    func testAnOpenFailureIsPropagatedAndNothingIsClosed() {
        let runtime = FakeTailscaleRuntime()
        runtime.openError = URLError(.cannotCreateFile)

        XCTAssertThrowsError(
            try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotCreateFile)
        }
        XCTAssertEqual(runtime.closed, [])
    }

    func testAStartFailureIsPropagatedAndTheHandleStaysOwnedByTheNode() async throws {
        let runtime = FakeTailscaleRuntime()
        runtime.startError = URLError(.cannotConnectToHost)
        let node = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)

        do {
            try await node.start()
            XCTFail("Expected the runtime's failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(runtime.closed, [])
        await node.stop()
        XCTAssertEqual(runtime.closed, [runtime.handle])
    }

    func testANodeCannotBeCreatedWithoutARuntime() {
        XCTAssertThrowsError(
            try EmbeddedTailscaleNode(
                directory: directory, hostname: "host", runtime: UnavailableTailscaleRuntime()
            )
        ) { error in
            XCTAssertEqual(error as? TailscaleUnavailableError, TailscaleUnavailableError())
        }
    }

    func testMalformedStatusIsReportedAsADecodingFailure() async throws {
        let runtime = FakeTailscaleRuntime()
        runtime.statusData = Data("not json".utf8)
        let node = try EmbeddedTailscaleNode(directory: directory, hostname: "host", runtime: runtime)

        do {
            _ = try await node.status()
            XCTFail("Expected a decoding failure")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
        await node.stop()
    }

    private func assertRejected(
        _ code: URLError.Code,
        _ call: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await call()
            XCTFail("Expected the stopped node to reject the call", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? URLError)?.code, code, file: file, line: line)
        }
    }
}

#if !canImport(CTailscale)
/// What a build without libtailscale (macOS) does when tailnet routing was
/// switched on, for example by preferences copied from another device.
@available(iOS 18.1, *)
final class TailscaleServiceWithoutRuntimeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TailscaleRouting.shared.configure(enabled: true, additionalHosts: ["music.internal"])
        addTeardownBlock {
            TailscaleRouting.shared.configure(enabled: false, additionalHosts: [])
        }
    }

    func testStatusReportsNothingConnectedInsteadOfFailing() async throws {
        let status = try await TailscaleService.shared.status()

        XCTAssertEqual(status, TailscaleStatusSnapshot())
        XCTAssertEqual(status.state, .disconnected)
    }

    func testConnectingFailsBecauseTheRuntimeIsMissing() async {
        do {
            _ = try await TailscaleService.shared.connect(webAuthentication: false)
            XCTFail("Expected the missing runtime to be reported")
        } catch {
            XCTAssertEqual(error as? TailscaleUnavailableError, TailscaleUnavailableError())
        }
    }

    func testTailnetAddressesStayOnTheDirectRoute() async throws {
        for address in ["http://100.64.0.1:4533", "http://music.internal", "https://nas.ts.net"] {
            let url = try XCTUnwrap(URL(string: address))
            let routed = try await NetworkService.prepareConnection(for: url)
            XCTAssertFalse(routed, address)
        }
    }

    func testForegroundValidationLeavesTheServiceIdle() async {
        await TailscaleService.shared.validateAfterForeground()
        let status = try? await TailscaleService.shared.status()
        XCTAssertEqual(status, TailscaleStatusSnapshot())
    }
}
#endif

// MARK: - Fixtures

private final class FakeTailscaleRuntime: TailscaleRuntime, @unchecked Sendable {
    struct Open: Equatable {
        var directory: URL
        var hostname: String
        var authKey: String?
    }

    let handle: Int32 = 42
    private let lock = NSLock()
    private var openCalls: [Open] = []
    private var startCalls: [Int32] = []
    private var closeCalls: [Int32] = []
    private var loopbacks = 0
    private var storedOpenError: Error?
    private var storedStartError: Error?
    private var storedStatus = Data(
        #"{"BackendState":"Running","Self":{"HostName":"aonsoku-test","TailscaleIPs":["100.64.0.9"]}}"#.utf8
    )

    var openError: Error? {
        get { lock.withLock { storedOpenError } }
        set { lock.withLock { storedOpenError = newValue } }
    }

    var startError: Error? {
        get { lock.withLock { storedStartError } }
        set { lock.withLock { storedStartError = newValue } }
    }

    var statusData: Data {
        get { lock.withLock { storedStatus } }
        set { lock.withLock { storedStatus = newValue } }
    }

    var opens: [Open] { lock.withLock { openCalls } }
    var started: [Int32] { lock.withLock { startCalls } }
    var closed: [Int32] { lock.withLock { closeCalls } }
    var loopbackCalls: Int { lock.withLock { loopbacks } }

    func open(directory: URL, hostname: String, authKey: String?) throws -> Int32 {
        if let error = openError { throw error }
        lock.withLock { openCalls.append(Open(directory: directory, hostname: hostname, authKey: authKey)) }
        return handle
    }

    func start(_ handle: Int32) throws {
        if let error = startError { throw error }
        lock.withLock { startCalls.append(handle) }
    }

    func statusJSON(_ handle: Int32) throws -> Data { statusData }

    func loopback(_ handle: Int32) throws -> TailscaleLoopback {
        lock.withLock { loopbacks += 1 }
        return TailscaleLoopback(address: "127.0.0.1:1055", password: "proxy-secret", localAPIKey: "api-key")
    }

    func close(_ handle: Int32) {
        lock.withLock { closeCalls.append(handle) }
    }
}
