import Foundation

/// The HTTP policies used by existing callers. Routing belongs to the network
/// service and can be selected per request without changing these callers.
public enum HTTPRequestProfile: Sendable, Hashable {
    case standard
    case subsonic
    case artwork
}

/// A small injectable HTTP boundary. Responses and errors retain URLSession's
/// semantics; authentication and response validation remain with the caller.
public struct HTTPClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    public init(session: URLSession) {
        self.init { request in try await session.data(for: request) }
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let result = try await transport(request)
        try Task.checkCancellation()
        return result
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }
}

/// Shared entry point for ordinary HTTP requests. Background downloads,
/// WebSockets and AVPlayer retain their dedicated transport lifecycles.
public final class NetworkService: Sendable {
    @TaskLocal static var diagnosticSource: String?
    public typealias Transport = @Sendable (
        URLRequest, HTTPRequestProfile
    ) async throws -> (Data, URLResponse)

    public static let shared = NetworkService()
    private let transport: Transport

    public convenience init() {
        let subsonicSession = URLSession(configuration: Self.configuration(for: .subsonic))
        let artworkSession = URLSession(configuration: Self.configuration(for: .artwork))

        self.init(prepareRoute: { url in try await Self.prepareConnection(for: url) }, direct: { request, profile in
            let session: URLSession
            switch profile {
            case .standard: session = .shared
            case .subsonic: session = subsonicSession
            case .artwork: session = artworkSession
            }
            return try await session.data(for: request)
        }, tailnet: { request, profile in
            if #available(iOS 18.1, *) { return try await TailscaleService.shared.data(for: request, profile: profile) }
            throw URLError(.unsupportedURL)
        })
    }

    init(prepareRoute: @escaping @Sendable (URL) async throws -> Bool,
         direct: @escaping Transport, tailnet: @escaping Transport) {
        self.transport = { request, profile in
            guard let url = request.url else { throw URLError(.badURL) }
            let start = ContinuousClock.now
            var route = "not-sent"
            do {
                let useTailnet = try await prepareRoute(url)
                try Task.checkCancellation()
                route = useTailnet ? "tailscale" : "direct"
                if let source = Self.diagnosticSource {
                    NativeLogger.shared.info("\(url.lastPathComponent) route=\(route) started", source: source)
                }
                let result = try await (useTailnet ? tailnet : direct)(request, profile)
                Self.logRequest(url: url, route: route, start: start,
                                result: "HTTP \((result.1 as? HTTPURLResponse)?.statusCode ?? 0)")
                return result
            } catch {
                let failure = error as NSError
                Self.logRequest(url: url, route: route, start: start,
                                result: "\(failure.domain) code=\(failure.code): \(error.localizedDescription)")
                throw error
            }
        }
    }

    private static func logRequest(url: URL, route: String, start: ContinuousClock.Instant, result: String) {
        guard let source = diagnosticSource else { return }
        let duration = start.duration(to: .now).components
        let milliseconds = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
        NativeLogger.shared.info("\(url.lastPathComponent) route=\(route) elapsed=\(milliseconds)ms \(result)", source: source)
    }

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    public func client(for profile: HTTPRequestProfile = .standard) -> HTTPClient {
        HTTPClient { request in try await self.transport(request, profile) }
    }

    static func configuration(for profile: HTTPRequestProfile) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        switch profile {
        case .standard: break
        case .subsonic:
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
        case .artwork:
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
        }
        return configuration
    }

    static func streamingSession(
        for url: URL, delegate: URLSessionDelegate, configuration: URLSessionConfiguration = .default
    ) async throws -> URLSession {
        let useTailnet = try await prepareConnection(for: url)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if #available(iOS 18.1, *), useTailnet {
            return try await TailscaleService.shared.makeSession(for: url, configuration: configuration, delegate: delegate)
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Public requests do not wait for Tailscale. Selected private destinations
    /// either obtain a ready transport or fail explicitly; never fall back.
    @discardableResult
    public static func prepareConnection(for url: URL) async throws -> Bool {
        guard #available(iOS 18.1, *), TailscaleRouting.shared.requiresTailscale(url) else { return false }
        try await TailscaleService.shared.ensureReady(for: url)
        return true
    }
}
