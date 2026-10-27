import Foundation

/// Exact additional hosts cover subnet-router/custom-DNS deployments without
/// sending unrelated public requests through the embedded node.
public struct TailscaleRoutePolicy: Sendable {
    public let additionalHosts: Set<String>

    public init(additionalHosts: [String] = []) {
        self.additionalHosts = Set(additionalHosts.compactMap(Self.host))
    }

    public func routes(_ url: URL) -> Bool {
        guard ["http", "https", "ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host.map(Self.normalize) else { return false }
        if additionalHosts.contains(host) || host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".")
        let octets = parts.compactMap { UInt8($0) }
        if parts.count == 4, octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return true }
        var address = in6_addr()
        if inet_pton(AF_INET6, host, &address) == 1 {
            return withUnsafeBytes(of: address) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
        }
        return false
    }

    private static func normalize(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
    }

    private static func host(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let host = URL(string: value.contains("://") ? value : "http://\(value)")?.host else { return nil }
        return normalize(host)
    }
}

public final class TailscaleRouting: @unchecked Sendable {
    public static let shared = TailscaleRouting()
    public struct Configuration: Codable, Sendable {
        public var enabled = false
        public var additionalHosts: [String] = []
    }
    private let lock = NSLock()
    private var configuration: Configuration
    private var peerHosts: [String] = []
    private let defaults: UserDefaults
    private static let key = "tailscale.configuration.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
    }

    public var current: Configuration { lock.withLock { configuration } }

    public func configure(enabled: Bool, additionalHosts: [String]) {
        lock.withLock {
            configuration = Configuration(enabled: enabled, additionalHosts:
                TailscaleRoutePolicy(additionalHosts: additionalHosts).additionalHosts.sorted())
            if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.key) }
        }
    }

    func updatePeers(_ hosts: [String]) { lock.withLock { peerHosts = hosts } }

    public func shouldRoute(_ url: URL) -> Bool {
        guard #available(iOS 18.1, *) else { return false }
        return lock.withLock {
            configuration.enabled && TailscaleRoutePolicy(
                additionalHosts: configuration.additionalHosts + peerHosts
            ).routes(url)
        }
    }
}
