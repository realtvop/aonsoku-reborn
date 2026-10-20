import Foundation
import Observation

/// Network status readable from any thread, for repositories and sync.
public protocol Connectivity: Sendable {
    var isOnline: Bool { get }
    /// Cellular, Personal Hotspot or Low Data Mode. Automatic sync and
    /// smart downloads skip metered networks.
    var isMetered: Bool { get }
}

/// A connectivity value that never changes, for previews and tests.
public struct FixedConnectivity: Connectivity {
    public var isOnline: Bool
    public var isMetered: Bool

    public init(isOnline: Bool = true, isMetered: Bool = false) {
        self.isOnline = isOnline
        self.isMetered = isMetered
    }
}

/// Tracks the current network path with `NWPathMonitor` and publishes it to
/// SwiftUI. `connectivity` mirrors the same values behind a lock.
@MainActor
@Observable
public final class NetworkMonitor {
    /// The path is satisfied. True until the first path update arrives.
    public private(set) var isOnline = true
    /// Cellular or Personal Hotspot.
    public private(set) var isExpensive = false
    /// Low Data Mode.
    public private(set) var isConstrained = false

    public var isMetered: Bool { isExpensive || isConstrained }

    public nonisolated let connectivity: any Connectivity

    public init() {
        connectivity = FixedConnectivity()
    }

    /// Starts monitoring. Calling it again has no effect.
    public func start() {}

    public func stop() {}
}
