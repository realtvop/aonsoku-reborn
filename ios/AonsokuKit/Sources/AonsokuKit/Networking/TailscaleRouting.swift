import Foundation

/// Routes only tailnet destinations, approved subnet prefixes, and exact custom
/// hosts. Default routes are excluded: accepting subnets does not use an exit node.
public struct TailscaleRoutePolicy: Sendable {
    public let additionalHosts: Set<String>
    private let subnets: [Subnet]

    public init(additionalHosts: [String] = [], subnetRoutes: [String] = []) {
        self.additionalHosts = Set(additionalHosts.compactMap(Self.host))
        self.subnets = subnetRoutes.compactMap(Subnet.init)
    }

    public func routes(_ url: URL) -> Bool {
        guard ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host.map(Self.normalize) else { return false }
        if additionalHosts.contains(host) || host.hasSuffix(".ts.net") { return true }
        if subnets.contains(where: { $0.contains(host) }) { return true }
        let parts = host.split(separator: ".")
        let octets = parts.compactMap { UInt8($0) }
        if parts.count == 4, octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return true }
        var address = in6_addr()
        if inet_pton(AF_INET6, host, &address) == 1 {
            return withUnsafeBytes(of: address) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
        }
        return false
    }

    func matchesSubnet(_ url: URL) -> Bool {
        guard let host = url.host.map(Self.normalize) else { return false }
        return subnets.contains { $0.contains(host) }
    }

    static func isIP(_ url: URL) -> Bool {
        url.host.flatMap { Subnet.address(normalize($0)) } != nil
    }

    static func isPrivateIP(_ url: URL) -> Bool {
        privateSubnets.contains { subnet in url.host.map { subnet.contains(normalize($0)) } == true }
    }

    private static let privateSubnets = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"].compactMap(Subnet.init)

    private static func normalize(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
    }

    private static func host(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let host = URL(string: value.contains("://") ? value : "http://\(value)")?.host else { return nil }
        return normalize(host)
    }

    private struct Subnet: Sendable {
        let bytes: [UInt8]
        let prefix: Int

        init?(_ cidr: String) {
            let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let prefix = Int(parts[1]), prefix > 0,
                  let bytes = Self.address(String(parts[0])), prefix <= bytes.count * 8 else { return nil }
            self.bytes = bytes
            self.prefix = prefix
        }

        func contains(_ host: String) -> Bool {
            guard let other = Self.address(host), other.count == bytes.count else { return false }
            let whole = prefix / 8
            guard bytes.prefix(whole) == other.prefix(whole) else { return false }
            let remainder = prefix % 8
            if remainder == 0 { return true }
            let mask = UInt8.max << (8 - remainder)
            return bytes[whole] & mask == other[whole] & mask
        }

        static func address(_ host: String) -> [UInt8]? {
            var ipv4 = in_addr()
            if inet_pton(AF_INET, host, &ipv4) == 1 { return withUnsafeBytes(of: ipv4) { Array($0) } }
            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, host, &ipv6) == 1 { return withUnsafeBytes(of: ipv6) { Array($0) } }
            return nil
        }
    }
}

public final class TailscaleRouting: @unchecked Sendable {
    public static let shared = TailscaleRouting()
    public struct Configuration: Codable, Sendable {
        public var enabled = false
        public var additionalHosts: [String] = []
        public var acceptSubnetRoutes = true

        public init() {}

        private enum CodingKeys: String, CodingKey { case enabled, additionalHosts, acceptSubnetRoutes }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            additionalHosts = try values.decodeIfPresent([String].self, forKey: .additionalHosts) ?? []
            acceptSubnetRoutes = try values.decodeIfPresent(Bool.self, forKey: .acceptSubnetRoutes) ?? true
        }
    }
    private let lock = NSLock()
    private var configuration: Configuration
    private var peerHosts: [String] = []
    private var knownPeers: Set<String> = []
    private var subnetRoutes: [String] = []
    private var policy = TailscaleRoutePolicy()
    private let defaults: UserDefaults
    private static let key = "tailscale.configuration.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        rebuildPolicy()
    }

    public var current: Configuration { lock.withLock { configuration } }

    public func configure(enabled: Bool, additionalHosts: [String], acceptSubnetRoutes: Bool? = nil) {
        lock.withLock {
            configuration.enabled = enabled
            configuration.additionalHosts = TailscaleRoutePolicy(additionalHosts: additionalHosts).additionalHosts.sorted()
            if let acceptSubnetRoutes { configuration.acceptSubnetRoutes = acceptSubnetRoutes }
            rebuildPolicy()
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.key) }
        }
    }

    func updatePeers(_ hosts: [String], subnetRoutes: [String] = []) {
        lock.withLock {
            peerHosts = hosts
            knownPeers = Set(hosts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")) })
            self.subnetRoutes = subnetRoutes
            rebuildPolicy()
        }
    }

    /// Called during initialization or with the lock held. Compile prefixes once
    /// per map update rather than parsing them for every artwork/audio request.
    private func rebuildPolicy() {
        policy = TailscaleRoutePolicy(
            additionalHosts: configuration.additionalHosts + peerHosts,
            subnetRoutes: configuration.acceptSubnetRoutes ? subnetRoutes : []
        )
    }

    public func shouldRoute(_ url: URL) -> Bool {
        guard #available(iOS 18.1, *) else { return false }
        return lock.withLock {
            configuration.enabled && policy.routes(url)
        }
    }

    /// Private IP targets in subnet mode must not fall back to a direct session
    /// while the control-plane map is still arriving. Public requests stay direct.
    public func requiresTailscale(_ url: URL) -> Bool {
        guard #available(iOS 18.1, *), ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return lock.withLock {
            configuration.enabled && (policy.routes(url) || (configuration.acceptSubnetRoutes && TailscaleRoutePolicy.isPrivateIP(url)))
        }
    }

    func hasAcceptedSubnetRoute(_ url: URL) -> Bool {
        lock.withLock { configuration.acceptSubnetRoutes && policy.matchesSubnet(url) }
    }

    func hasKnownPeer(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]")) else { return false }
        return lock.withLock { knownPeers.contains(host) }
    }
}
