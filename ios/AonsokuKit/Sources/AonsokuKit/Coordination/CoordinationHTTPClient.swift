import Foundation

/// `CoordinationAPIClient` over HTTPS. Port of
/// `src/coordination/httpClient.ts`.
final class CoordinationHTTPClient: CoordinationAPIClient, @unchecked Sendable {
    /// - Parameters:
    ///   - baseURL: The coordination server URL; a trailing slash is ignored.
    ///   - tokenStore: Supplies the current tokens and persists rotated or
    ///     cleared ones.
    ///   - recoveryProof: Builds a proof from the current Subsonic
    ///     credentials when the server rejects the refresh token; nil when
    ///     none are available.
    ///   - transport: Performs requests; defaults to `URLSession.shared`.
    ///   - now: Clock used for token expiry.
    init(
        baseURL: String,
        tokenStore: CoordinationTokenStoring,
        recoveryProof: @escaping @Sendable () -> CoordinationSubsonicProof?,
        transport: @escaping CoordinationTransport = CoordinationHTTPClient.urlSessionTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {}

    static let urlSessionTransport: CoordinationTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoordinationError(code: CoordinationErrorCode.internal)
        }
        return (data, http)
    }

    func register(
        proof: CoordinationSubsonicProof,
        device: CoordinationDeviceRegistration
    ) async throws -> CoordinationTokens {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    func webSocketTicket() async throws -> String {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    func listDevices() async throws -> [CoordinationDevice] {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    func renameDevice(id: String, name: String) async throws -> CoordinationDevice {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    func revokeDevice(id: String) async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }

    func deleteAccount() async throws {
        throw CoordinationError(code: CoordinationErrorCode.notConnected)
    }
}
