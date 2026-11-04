import Foundation

#if canImport(CTailscale)
import CTailscale
#endif

/// Whether this build can run the embedded Tailscale node.
///
/// `@available(iOS 18.1, *)` also matches every macOS version, and the
/// libtailscale archive has no macOS slice, so an availability annotation
/// cannot say "iOS only". Anything that must not engage tailnet routing
/// without the runtime asks this instead of (or in addition to) `#available`.
public enum TailscaleSupport {
    public static var isAvailable: Bool {
        #if canImport(CTailscale)
        if #available(iOS 18.1, *) { return true }
        #endif
        return false
    }
}

public struct TailscaleUnavailableError: LocalizedError, Equatable, Sendable {
    public init() {}

    public var errorDescription: String? {
        "Tailscale is not available on this platform."
    }
}

/// Where a node's SOCKS proxy and LocalAPI listen, as reported by libtailscale.
struct TailscaleLoopback: Equatable, Sendable {
    var address: String
    var password: String
    var localAPIKey: String
}

/// The libtailscale C API reduced to what `EmbeddedTailscaleNode` needs, so the
/// node can be tested with a fake and so builds without the C archive (macOS)
/// still contain the node, reporting it unavailable.
protocol TailscaleRuntime: Sendable {
    /// Creates and configures a node. The handle belongs to the caller until
    /// it is passed to `close`.
    func open(directory: URL, hostname: String, authKey: String?) throws -> Int32
    func start(_ handle: Int32) throws
    func statusJSON(_ handle: Int32) throws -> Data
    func loopback(_ handle: Int32) throws -> TailscaleLoopback
    func close(_ handle: Int32)
}

enum TailscaleRuntimes {
    /// The runtime this build links: libtailscale on iOS, none elsewhere.
    static var platform: any TailscaleRuntime {
        #if canImport(CTailscale)
        LibTailscaleRuntime()
        #else
        UnavailableTailscaleRuntime()
        #endif
    }
}

/// Stands in where libtailscale is not linked. Every call fails with
/// `TailscaleUnavailableError`.
struct UnavailableTailscaleRuntime: TailscaleRuntime {
    func open(directory: URL, hostname: String, authKey: String?) throws -> Int32 {
        throw TailscaleUnavailableError()
    }

    func start(_ handle: Int32) throws { throw TailscaleUnavailableError() }
    func statusJSON(_ handle: Int32) throws -> Data { throw TailscaleUnavailableError() }
    func loopback(_ handle: Int32) throws -> TailscaleLoopback { throw TailscaleUnavailableError() }
    func close(_ handle: Int32) {}
}

#if canImport(CTailscale)

/// Calls the official libtailscale runtime that ships in `CTailscale`.
struct LibTailscaleRuntime: TailscaleRuntime {
    func open(directory: URL, hostname: String, authKey: String?) throws -> Int32 {
        let value = tailscale_new()
        guard value > 0 else { throw URLError(.cannotConnectToHost) }
        tailscale_set_logfd(value, -1)
        tailscale_set_ephemeral(value, 0)
        guard tailscale_set_dir(value, directory.path) == 0,
              tailscale_set_hostname(value, hostname) == 0 else {
            tailscale_close(value)
            throw URLError(.cannotCreateFile)
        }
        if let authKey, !authKey.isEmpty {
            guard tailscale_set_authkey(value, authKey) == 0 else {
                tailscale_close(value)
                throw URLError(.userAuthenticationRequired)
            }
        }
        return value
    }

    func start(_ handle: Int32) throws {
        guard tailscale_start(handle) == 0 else {
            throw URLError(.cannotConnectToHost)
        }
    }

    func statusJSON(_ handle: Int32) throws -> Data {
        var pointer: UnsafeMutablePointer<CChar>?
        guard tailscale_status_json(handle, &pointer) == 0, let pointer else {
            throw URLError(.cannotConnectToHost)
        }
        defer { free(pointer) }
        return Data(bytes: pointer, count: strlen(pointer))
    }

    func loopback(_ handle: Int32) throws -> TailscaleLoopback {
        var address = [CChar](repeating: 0, count: 128)
        var password = [CChar](repeating: 0, count: 33)
        var localAPI = [CChar](repeating: 0, count: 33)
        guard tailscale_loopback(handle, &address, address.count, &password, &localAPI) == 0 else {
            throw URLError(.cannotConnectToHost)
        }
        return TailscaleLoopback(
            address: String(cString: address),
            password: String(cString: password),
            localAPIKey: String(cString: localAPI)
        )
    }

    func close(_ handle: Int32) {
        tailscale_close(handle)
    }
}

#endif
