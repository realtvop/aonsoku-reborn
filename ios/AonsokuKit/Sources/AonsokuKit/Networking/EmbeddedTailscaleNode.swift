import Foundation
import Network

/// A small Swift facade over the same official libtailscale runtime used by
/// TailscaleKit. No VPN extension or system-wide routing is installed. The C
/// calls live behind `TailscaleRuntime`; builds without the C archive (macOS)
/// get a runtime that fails every call with `TailscaleUnavailableError`.
@available(iOS 18.1, *)
actor EmbeddedTailscaleNode {
    struct Status: Decodable, Sendable {
        struct PeerStatus: Decodable, Sendable {
            var HostName: String?
            var DNSName: String?
            var TailscaleIPs: [String]?
            // Control-plane-approved routes for which this peer is selected.
            // Unlike advertised routes, these are ready for client routing.
            var PrimaryRoutes: [String]?
        }
        var BackendState: String?
        var AuthURL: String?
        var `Self`: PeerStatus?
        var Peer: [String: PeerStatus]?
        var Health: [String]?
        var isRunning: Bool { BackendState == "Running" }
    }

    struct Proxy: Sendable {
        let address: String
        let password: String
        let localAPIKey: String

        func apply(to configuration: URLSessionConfiguration, matching hosts: [String] = []) throws {
            guard let separator = address.lastIndex(of: ":"),
                  let port = UInt16(address[address.index(after: separator)...]),
                  let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw URLError(.cannotConnectToHost)
            }
            let host = String(address[..<separator])
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(host), port: endpointPort))
            proxy.applyCredential(username: "tsnet", password: password)
            proxy.allowFailover = false
            proxy.matchDomains = Array(Set(hosts.flatMap {
                [$0, $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))]
            }))
            configuration.proxyConfigurations = [proxy]
        }
    }

    private let runtime: any TailscaleRuntime
    private var handle: Int32?
    private var proxy: Proxy?
    private var acceptsSubnetRoutes: Bool?

    init(
        directory: URL,
        hostname: String,
        authKey: String? = nil,
        runtime: any TailscaleRuntime = TailscaleRuntimes.platform
    ) throws {
        self.runtime = runtime
        handle = try runtime.open(directory: directory, hostname: hostname, authKey: authKey)
    }

    deinit {
        if let handle { runtime.close(handle) }
    }

    func start() throws {
        guard let handle else { throw URLError(.cannotConnectToHost) }
        try runtime.start(handle)
    }

    func stop() {
        guard let value = handle else { return }
        handle = nil
        proxy = nil
        runtime.close(value)
    }

    func status() throws -> Status {
        guard let handle else { throw URLError(.notConnectedToInternet) }
        return try JSONDecoder().decode(Status.self, from: runtime.statusJSON(handle))
    }

    func loopback() throws -> Proxy {
        if let proxy { return proxy }
        guard let handle else { throw URLError(.notConnectedToInternet) }
        let value = try runtime.loopback(handle)
        let result = Proxy(address: value.address, password: value.password,
                           localAPIKey: value.localAPIKey)
        proxy = result
        return result
    }

    func beginWebAuthentication() async throws {
        try await localAPI("start", body: Data("{}".utf8))
        try await localAPI("login-interactive")
    }

    func setAcceptSubnetRoutes(_ enabled: Bool) async throws {
        guard acceptsSubnetRoutes != enabled else { return }
        let body = try JSONSerialization.data(withJSONObject: ["RouteAll": enabled, "RouteAllSet": true])
        try await localAPI("prefs", body: body, method: "PATCH")
        acceptsSubnetRoutes = enabled
    }

    func cancelWebAuthentication() async {
        try? await localAPI("reset-auth")
    }

    func logout() async throws {
        try await localAPI("logout")
    }

    func verifyLoopback() async throws { try await localAPI("status", method: "GET") }

    private func localAPI(_ endpoint: String, body: Data? = nil, method: String = "POST") async throws {
        let proxy = try loopback()
        let configuration = URLSessionConfiguration.ephemeral
        try proxy.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://\(proxy.address)/localapi/v0/\(endpoint)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("localapi", forHTTPHeaderField: "Sec-Tailscale")
        let credential = Data("tsnet:\(proxy.localAPIKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw URLError(.userAuthenticationRequired) }
    }
}
