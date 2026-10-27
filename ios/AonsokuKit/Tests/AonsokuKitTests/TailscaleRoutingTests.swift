import XCTest
@testable import AonsokuKit

final class TailscaleRoutingTests: XCTestCase {
    func testApprovedSubnetBoundariesAcrossAddressFamilies() {
        let policy = TailscaleRoutePolicy(subnetRoutes: ["192.168.8.0/23", "10.8.0.4/31", "2001:db8:1234:5600::/57"])
        for host in ["192.168.8.0", "192.168.9.255", "10.8.0.4", "10.8.0.5", "[2001:db8:1234:567f:ffff::1]"] {
            XCTAssertTrue(policy.routes(URL(string: "http://\(host):4533/rest/ping")!), host)
        }
        for host in ["192.168.7.255", "192.168.10.0", "10.8.0.3", "10.8.0.6", "[2001:db8:1234:5680::1]", "music.internal"] {
            XCTAssertFalse(policy.routes(URL(string: "http://\(host)")!), host)
        }
    }

    func testSubnetAcceptanceDoesNotSelectExitNodesOrMalformedRoutes() {
        let policy = TailscaleRoutePolicy(subnetRoutes: ["0.0.0.0/0", "::/0", "10.0.0.0/33", "2001:db8::/129", "192.168.0.0/-1", "192.168.0.0", "invalid/24"])
        for host in ["1.1.1.1", "192.168.0.1", "[2606:4700:4700::1111]", "[2001:db8::1]"] {
            XCTAssertFalse(policy.routes(URL(string: "https://\(host)")!), host)
        }
        let hostRoutes = TailscaleRoutePolicy(subnetRoutes: ["10.2.3.4/32", "2001:db8::1/128"])
        XCTAssertTrue(hostRoutes.routes(URL(string: "http://10.2.3.4")!))
        XCTAssertFalse(hostRoutes.routes(URL(string: "http://10.2.3.5")!))
        XCTAssertTrue(hostRoutes.routes(URL(string: "http://[2001:db8::1]")!))
        XCTAssertFalse(hostRoutes.routes(URL(string: "http://[2001:db8::2]")!))
    }

    func testSubnetPreferenceMigrationPersistenceAndRouteWithdrawal() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tailscale-test-\(UUID().uuidString)"))
        defaults.set(Data(#"{"enabled":true,"additionalHosts":["music.internal"]}"#.utf8), forKey: "tailscale.configuration.v1")
        let routing = TailscaleRouting(defaults: defaults)
        XCTAssertTrue(routing.current.enabled)
        XCTAssertEqual(routing.current.additionalHosts, ["music.internal"])
        XCTAssertTrue(routing.current.acceptSubnetRoutes)
        let server = URL(string: "http://192.168.8.10:4533")!
        routing.updatePeers([], subnetRoutes: ["192.168.8.0/24"])
        if #available(iOS 18.1, *) { XCTAssertTrue(routing.shouldRoute(server)) }
        routing.configure(enabled: true, additionalHosts: ["music.internal"], acceptSubnetRoutes: false)
        XCTAssertFalse(routing.shouldRoute(server))
        let restored = TailscaleRouting(defaults: defaults)
        XCTAssertFalse(restored.current.acceptSubnetRoutes)
        restored.configure(enabled: true, additionalHosts: [])
        XCTAssertFalse(restored.current.acceptSubnetRoutes)
        routing.configure(enabled: true, additionalHosts: ["music.internal"], acceptSubnetRoutes: true)
        if #available(iOS 18.1, *) {
            XCTAssertTrue(routing.shouldRoute(server))
            XCTAssertTrue(routing.shouldRoute(URL(string: "http://100.64.0.1")!))
            XCTAssertTrue(routing.shouldRoute(URL(string: "http://music.internal")!))
        }
        routing.updatePeers([])
        XCTAssertFalse(routing.shouldRoute(server))
        // Control-plane routes are never restored from preferences.
        XCTAssertFalse(TailscaleRouting(defaults: defaults).shouldRoute(server))
    }

    func testStatusDecodesControlPlaneSelectedRoutes() throws {
        if #available(iOS 18.1, *) {
            let data = Data(#"{"BackendState":"Running","Peer":{"router":{"TailscaleIPs":["100.64.0.2"],"AllowedIPs":["100.64.0.2/32","192.168.8.0/24","192.168.9.0/24"],"PrimaryRoutes":["192.168.8.0/24"]},"unapproved":{"TailscaleIPs":["100.64.0.3"]}}}"#.utf8)
            let status = try JSONDecoder().decode(EmbeddedTailscaleNode.Status.self, from: data)
            let routes = try XCTUnwrap(status.Peer).values.flatMap { $0.PrimaryRoutes ?? [] }
            let policy = TailscaleRoutePolicy(subnetRoutes: routes)
            XCTAssertTrue(policy.routes(URL(string: "http://192.168.8.10")!))
            XCTAssertFalse(policy.routes(URL(string: "http://192.168.9.10")!))
        }
    }

    func testTailnetAddressBoundariesAndPublicTraffic() {
        let policy = TailscaleRoutePolicy()
        for target in ["http://100.64.0.1:4533", "https://100.127.255.254", "http://[fd7a:115c:a1e0::1]", "wss://music.example.ts.net/socket"] {
            XCTAssertTrue(policy.routes(URL(string: target)!), target)
        }
        for target in ["http://100.63.255.255", "http://100.128.0.1", "https://example.com", "https://not-ts.net", "https://music.ts.net.attacker.example", "http://[fd7a:115c:a1e1::1]", "file:///tmp/audio.mp3"] {
            XCTAssertFalse(policy.routes(URL(string: target)!), target)
        }
    }

    func testAdditionalServerHostsAreExactAndStoredWithoutCredentials() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tailscale-test-\(UUID().uuidString)"))
        let routing = TailscaleRouting(defaults: defaults)
        routing.configure(enabled: false, additionalHosts: ["https://user:secret@Music.Internal:4533/base?token=secret"])
        XCTAssertEqual(routing.current.additionalHosts, ["music.internal"])
        XCTAssertFalse(routing.shouldRoute(URL(string: "https://music.internal")!))
        let policy = TailscaleRoutePolicy(additionalHosts: routing.current.additionalHosts)
        XCTAssertTrue(policy.routes(URL(string: "https://music.internal/rest/ping")!))
        XCTAssertFalse(policy.routes(URL(string: "https://music.internal.attacker.example")!))
        XCTAssertFalse(policy.routes(URL(string: "https://other.internal")!))
    }
}
