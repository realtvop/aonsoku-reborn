import Foundation

/// The HTTP policies used by existing callers. Routing belongs to the network
/// service and can be selected per request without changing these callers.
public enum HTTPRequestProfile: Sendable {
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
        let subsonic = URLSessionConfiguration.default
        subsonic.timeoutIntervalForRequest = 30
        subsonic.timeoutIntervalForResource = 300
        let subsonicSession = URLSession(configuration: subsonic)

        let artwork = URLSessionConfiguration.default
        artwork.timeoutIntervalForRequest = 30
        artwork.timeoutIntervalForResource = 120
        let artworkSession = URLSession(configuration: artwork)

        self.init { request, profile in
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
}
