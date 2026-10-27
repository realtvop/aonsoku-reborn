import XCTest
@testable import AonsokuKit

final class TailscaleRoutingTests: XCTestCase {
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
