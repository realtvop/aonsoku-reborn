import Foundation

public struct TailscaleStatusSnapshot: Equatable, Sendable {
    public enum State: String, Sendable {
        case disconnected, connecting, needsLogin, needsApproval, connected, failed
    }
    public var state: State = .disconnected
    public var authenticationURL: URL?
    public var hostname: String = ""
    public var addresses: [String] = []
}

/// Owns a separate, persistent tailnet identity for this installation. Subsonic
/// authentication remains independent; node keys never enter app preferences.
@available(iOS 18.1, *)
public actor TailscaleService {
    public static let shared = TailscaleService()
    private var node: EmbeddedTailscaleNode?
    private var starting: Task<EmbeddedTailscaleNode, Error>?
    private var revision: UInt64 = 0
    private var sessions: [String: URLSession] = [:]
    private var routeMonitor: Task<Void, Never>?
    private var routingUpdatedAt: Date?

    /// Refresh before selecting a transport so a cold launch can use subnet
    /// addresses without first visiting settings. Failures retain the last map.
    func prepareRouting() async {
        guard !Task.isCancelled, TailscaleRouting.shared.current.enabled else { return }
        if let routingUpdatedAt, Date().timeIntervalSince(routingUpdatedAt) < 2 { return }
        _ = try? await status()
    }

    public func updateRoutingPreferences() async throws {
        routingUpdatedAt = nil
        for session in sessions.values { session.invalidateAndCancel() }
        sessions.removeAll()
        _ = try await status()
    }

    public func connect(authKey: String? = nil, webAuthentication: Bool = true) async throws -> TailscaleStatusSnapshot {
        if let authKey, !authKey.isEmpty { await stop() }
        let node = try await ensureNode(authKey: authKey)
        if webAuthentication, !(try await node.status()).isRunning {
            try await node.beginWebAuthentication()
        }
        for _ in 0..<20 {
            try Task.checkCancellation()
            let value = try await status()
            if value.state == .connected || value.state == .needsApproval || value.authenticationURL != nil { return value }
            try await Task.sleep(for: .milliseconds(250))
        }
        return try await status()
    }

    public func status() async throws -> TailscaleStatusSnapshot {
        guard TailscaleRouting.shared.current.enabled else { return TailscaleStatusSnapshot() }
        let generation = revision
        let node = try await ensureNode()
        let value = try await node.status()
        guard generation == revision else { throw CancellationError() }
        let peers = value.Peer.map { Array($0.values) } ?? []
        TailscaleRouting.shared.updatePeers(peers.flatMap { peer in
            [peer.HostName, peer.DNSName].compactMap { $0 } + (peer.TailscaleIPs ?? [])
        }, subnetRoutes: value.isRunning ? peers.flatMap { $0.PrimaryRoutes ?? [] } : [])
        routingUpdatedAt = Date()
        let state: TailscaleStatusSnapshot.State
        switch value.BackendState {
        case "Running": state = .connected
        case "NeedsLogin": state = .needsLogin
        case "NeedsMachineAuth": state = .needsApproval
        case "Stopped": state = .disconnected
        default: state = .connecting
        }
        let authURL = value.AuthURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return TailscaleStatusSnapshot(state: state, authenticationURL: authURL,
                                      hostname: value.`Self`?.HostName ?? "", addresses: value.`Self`?.TailscaleIPs ?? [])
    }

    public func cancelAuthentication() async {
        await node?.cancelWebAuthentication()
        await stop()
    }

    public func stop() async {
        revision &+= 1
        let node = self.node
        let pending = starting
        self.node = nil
        starting = nil
        routeMonitor?.cancel()
        routeMonitor = nil
        routingUpdatedAt = nil
        for session in sessions.values { session.invalidateAndCancel() }
        sessions.removeAll()
        TailscaleRouting.shared.updatePeers([])
        pending?.cancel()
        await node?.stop()
        if let pending, let value = try? await pending.value { await value.stop() }
    }

    public func forgetIdentity() async throws {
        if let node { try? await node.logout() }
        await stop()
        let directory = try Self.stateDirectory()
        try FileManager.default.removeItem(at: directory)
    }

    public func validateAfterForeground() async {
        guard TailscaleRouting.shared.current.enabled else { return }
        do {
            if let node { try await node.verifyLoopback() }
        } catch {
            // The OS can reclaim the loopback listener while suspended. Keep
            // persisted keys, but recreate the node and all proxy sessions.
            await stop()
        }
        routingUpdatedAt = nil
        await prepareRouting()
    }

    func data(for request: URLRequest, profile: HTTPRequestProfile) async throws -> (Data, URLResponse) {
        let generation = revision
        guard let url = request.url else { throw URLError(.badURL) }
        let key = "\(profile):\(url.host ?? "")"
        let session: URLSession
        if let cached = sessions[key] {
            session = cached
        } else {
            session = try await makeSession(for: url, configuration: NetworkService.configuration(for: profile))
            guard generation == revision else { session.invalidateAndCancel(); throw CancellationError() }
            sessions[key] = session
        }
        return try await session.data(for: request)
    }

    func makeSession(
        for url: URL, configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil
    ) async throws -> URLSession {
        try await configureSession(for: url, configuration: configuration)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func configureSession(for url: URL, configuration: URLSessionConfiguration) async throws {
        let generation = revision
        let node = try await ensureNode()
        guard (try await node.status()).isRunning else { throw URLError(.userAuthenticationRequired) }
        let proxy = try await node.loopback()
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        try proxy.apply(to: configuration, matching: url.host.map { [$0] } ?? [])
    }

    private func ensureNode(authKey: String? = nil) async throws -> EmbeddedTailscaleNode {
        guard TailscaleRouting.shared.current.enabled else { throw URLError(.notConnectedToInternet) }
        if let node {
            try await node.setAcceptSubnetRoutes(TailscaleRouting.shared.current.acceptSubnetRoutes)
            return node
        }
        let generation = revision
        let pending: Task<EmbeddedTailscaleNode, Error>
        if let starting {
            pending = starting
        } else {
            let directory = try Self.stateDirectory()
            pending = Task {
                let node = try EmbeddedTailscaleNode(directory: directory, hostname: "aonsoku-ios", authKey: authKey)
                do {
                    try Task.checkCancellation()
                    try await node.start()
                    try await node.setAcceptSubnetRoutes(TailscaleRouting.shared.current.acceptSubnetRoutes)
                    return node
                } catch {
                    await node.stop()
                    throw error
                }
            }
            starting = pending
        }
        do {
            let value = try await pending.value
            guard generation == revision else { await value.stop(); throw CancellationError() }
            node = value
            starting = nil
            if routeMonitor == nil {
                routeMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        await self?.prepareRouting()
                    }
                }
            }
            return value
        } catch {
            if generation == revision { starting = nil }
            throw error
        }
    }

    private static func stateDirectory() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("Aonsoku/Tailscale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return directory
    }
}
