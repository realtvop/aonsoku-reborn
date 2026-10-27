import XCTest
@testable import AonsokuKit

final class TailscaleReadinessTests: XCTestCase {
    func testMissingSubnetRouteFailsWithoutOpeningEitherTransport() async throws {
        let gate = TailscaleReadinessGate()
        let calls = LockedTestBox<[String]>([])
        let network = NetworkService(prepareRoute: { url in
            try await gate.wait(for: url.host!, timeout: .milliseconds(30), interval: .milliseconds(5)) {
                .waiting(.missingSubnetRoute(url.host!))
            }
            return true
        }, direct: { _, _ in
            calls.update { $0.append("direct") }; throw URLError(.badServerResponse)
        }, tailnet: { _, _ in
            calls.update { $0.append("tailnet") }; throw URLError(.badServerResponse)
        })
        do {
            _ = try await network.client().data(from: URL(string: "http://192.168.50.123/rest/ping.view")!)
            XCTFail("Missing route must fail")
        } catch let error as TailscaleReadinessError {
            XCTAssertEqual(error, .missingSubnetRoute("192.168.50.123"))
        }
        XCTAssertTrue(calls.read { $0.isEmpty })
    }

    func testWaitsUntilReadyAndNeverUsesDirectFallback() async throws {
        let gate = TailscaleReadinessGate()
        let probes = LockedTestBox(0)
        let network = NetworkService(prepareRoute: { url in
            try await gate.wait(for: url.host!, interval: .milliseconds(1)) {
                probes.update { $0 += 1 }
                return probes.read { $0 < 3 } ? .waiting(.connectionTimedOut) : .ready
            }
            return true
        }, direct: { _, _ in
            XCTFail("Selected server must not go direct"); throw URLError(.badServerResponse)
        }, tailnet: { request, _ in
            XCTAssertGreaterThanOrEqual(probes.read { $0 }, 3)
            return (Data("ok".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let (data, _) = try await network.client().data(from: URL(string: "http://192.168.50.123")!)
        XCTAssertEqual(data, Data("ok".utf8))
    }

    func testOneWaiterCanCancelWithoutCancelingSharedConnection() async throws {
        let gate = TailscaleReadinessGate()
        let entered = expectation(description: "Shared probe entered")
        let release = LockedTestBox<CheckedContinuation<Void, Never>?>(nil)
        let first = Task {
            try await gate.wait(for: "server") {
                await withCheckedContinuation { continuation in
                    release.update { $0 = continuation }; entered.fulfill()
                }
                return .ready
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        let second = Task {
            try await gate.wait(for: "server") {
                XCTFail("A second worker must not be started"); return .ready
            }
        }
        // Register the second caller before canceling the first.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await gate.waiterCount(for: "server") < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let count = await gate.waiterCount(for: "server")
        XCTAssertEqual(count, 2)
        first.cancel()
        do { try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        release.read { $0 }?.resume()
        try await second.value
    }

    func testPrivateSubnetTargetsRequireReadinessBeforeMapArrives() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "readiness-\(UUID().uuidString)"))
        let routing = TailscaleRouting(defaults: defaults)
        routing.configure(enabled: true, additionalHosts: [])
        if #available(iOS 18.1, *) {
            XCTAssertTrue(routing.requiresTailscale(URL(string: "http://192.168.50.123")!))
            XCTAssertFalse(routing.hasAcceptedSubnetRoute(URL(string: "http://192.168.50.123")!))
            XCTAssertFalse(routing.requiresTailscale(URL(string: "https://example.com")!))
            routing.updatePeers([], subnetRoutes: ["192.168.50.0/24"])
            XCTAssertTrue(routing.hasAcceptedSubnetRoute(URL(string: "http://192.168.50.123")!))
            routing.configure(enabled: false, additionalHosts: [])
            XCTAssertFalse(routing.requiresTailscale(URL(string: "http://192.168.50.123")!))
        }
    }
}
