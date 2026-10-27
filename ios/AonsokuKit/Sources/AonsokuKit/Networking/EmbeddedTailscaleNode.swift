import CTailscale
import Foundation
import Network

/// A small Swift facade over the same official libtailscale runtime used by
/// TailscaleKit. No VPN extension or system-wide routing is installed.
@available(iOS 18.1, *)
actor EmbeddedTailscaleNode {
    struct Status: Decodable, Sendable {
        struct PeerStatus: Decodable, Sendable {
            var HostName: String?
            var DNSName: String?
            var TailscaleIPs: [String]?
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

        func apply(to configuration: URLSessionConfiguration) throws {
            guard let separator = address.lastIndex(of: ":"),
                  let port = UInt16(address[address.index(after: separator)...]),
                  let endpointPort = NWEndpoint.Port(rawValue: port) else {
                throw URLError(.cannotConnectToHost)
            }
            let host = String(address[..<separator])
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(host), port: endpointPort))
            proxy.applyCredential(username: "tsnet", password: password)
            proxy.allowFailover = false
            configuration.proxyConfigurations = [proxy]
        }
    }

    private var handle: Int32?
    private var proxy: Proxy?

    init(directory: URL, hostname: String, authKey: String? = nil) throws {
        let value = tailscale_new()
        guard value > 0 else { throw URLError(.cannotConnectToHost) }
        handle = value
        tailscale_set_logfd(value, -1)
        tailscale_set_ephemeral(value, 0)
        guard tailscale_set_dir(value, directory.path) == 0,
              tailscale_set_hostname(value, hostname) == 0 else {
            tailscale_close(value)
            handle = nil
            throw URLError(.cannotCreateFile)
        }
        if let authKey, !authKey.isEmpty {
            guard tailscale_set_authkey(value, authKey) == 0 else {
                tailscale_close(value)
                handle = nil
                throw URLError(.userAuthenticationRequired)
            }
        }
    }

    deinit {
        if let handle { tailscale_close(handle) }
    }

    func start() throws {
        guard let handle, tailscale_start(handle) == 0 else {
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() {
        guard let value = handle else { return }
        handle = nil
        proxy = nil
        tailscale_close(value)
    }

    func status() throws -> Status {
        guard let handle else { throw URLError(.notConnectedToInternet) }
        var pointer: UnsafeMutablePointer<CChar>?
        guard tailscale_status_json(handle, &pointer) == 0, let pointer else {
            throw URLError(.cannotConnectToHost)
        }
        defer { free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        return try JSONDecoder().decode(Status.self, from: data)
    }

    func loopback() throws -> Proxy {
        if let proxy { return proxy }
        guard let handle else { throw URLError(.notConnectedToInternet) }
        var address = [CChar](repeating: 0, count: 128)
        var password = [CChar](repeating: 0, count: 33)
        var localAPI = [CChar](repeating: 0, count: 33)
        guard tailscale_loopback(handle, &address, address.count, &password, &localAPI) == 0 else {
            throw URLError(.cannotConnectToHost)
        }
        let result = Proxy(address: String(cString: address), password: String(cString: password),
                           localAPIKey: String(cString: localAPI))
        proxy = result
        return result
    }

    func beginWebAuthentication() async throws {
        try await localAPI("start", body: Data("{}".utf8))
        try await localAPI("login-interactive")
    }

    func cancelWebAuthentication() async {
        try? await localAPI("reset-auth")
    }

    func logout() async throws {
        try await localAPI("logout")
    }

    private func localAPI(_ endpoint: String, body: Data? = nil) async throws {
        let proxy = try loopback()
        let configuration = URLSessionConfiguration.ephemeral
        try proxy.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://\(proxy.address)/localapi/v0/\(endpoint)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
