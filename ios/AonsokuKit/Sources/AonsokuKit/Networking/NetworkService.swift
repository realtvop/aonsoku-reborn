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
    public typealias Transport = @Sendable (
        URLRequest, HTTPRequestProfile
    ) async throws -> (Data, URLResponse)

    public static let shared = NetworkService()
    private let transport: Transport

    public convenience init() {
        let subsonicSession = URLSession(configuration: Self.configuration(for: .subsonic))
        let artworkSession = URLSession(configuration: Self.configuration(for: .artwork))

        self.init { request, profile in
            await Self.prepareTailscaleRouting()
            if #available(iOS 18.1, *), let url = request.url, TailscaleRouting.shared.shouldRoute(url) {
                return try await TailscaleService.shared.data(for: request, profile: profile)
            }
            let session: URLSession
            switch profile {
            case .standard: session = .shared
            case .subsonic: session = subsonicSession
            case .artwork: session = artworkSession
            }
            return try await session.data(for: request)
        }
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
        await prepareTailscaleRouting()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if #available(iOS 18.1, *), TailscaleRouting.shared.shouldRoute(url) {
            return try await TailscaleService.shared.makeSession(for: url, configuration: configuration, delegate: delegate)
        }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func prepareTailscaleRouting() async {
        if #available(iOS 18.1, *) { await TailscaleService.shared.prepareRouting() }
    }
}
