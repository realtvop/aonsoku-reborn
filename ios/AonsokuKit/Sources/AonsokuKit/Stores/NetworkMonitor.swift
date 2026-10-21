import Foundation
import Network
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
    @ObservationIgnored private nonisolated let sharedConnectivity: LockedConnectivity
    @ObservationIgnored private nonisolated let queue = DispatchQueue(
        label: "github.realtvop.aonsoku.network-monitor"
    )
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var generation = UUID()

    public init() {
        let sharedConnectivity = LockedConnectivity(isOnline: true, isMetered: false)
        self.sharedConnectivity = sharedConnectivity
        connectivity = sharedConnectivity
    }

    /// Starts monitoring. Calling it again has no effect.
    public func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        let generation = UUID()
        self.generation = generation
        self.monitor = monitor
        let sharedConnectivity = sharedConnectivity
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            sharedConnectivity.update(
                isOnline: online,
                isMetered: expensive || constrained
            )
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.isOnline = online
                self.isExpensive = expensive
                self.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        generation = UUID()
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
    }
}

final class LockedConnectivity: Connectivity, @unchecked Sendable {
    private let lock = NSLock()
    private var state: (isOnline: Bool, isMetered: Bool)

    init(isOnline: Bool, isMetered: Bool) {
        state = (isOnline, isMetered)
    }

    var isOnline: Bool { withState { $0.isOnline } }
    var isMetered: Bool { withState { $0.isMetered } }

    func update(isOnline: Bool, isMetered: Bool) {
        lock.lock()
        state = (isOnline, isMetered)
        lock.unlock()
    }

    private func withState<T>(_ read: ((isOnline: Bool, isMetered: Bool)) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return read(state)
    }
}
