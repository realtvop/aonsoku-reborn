import Foundation
import Network
import Perception

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

/// What a network path looked like, reduced to what decides whether the
/// connections opened before it may still work.
struct NetworkPathState: Equatable, Sendable {
    var isOnline: Bool
    var isExpensive: Bool
    var isConstrained: Bool
    /// The kinds of interface the path may use.
    var interfaces: Set<NWInterface.InterfaceType>
}

/// Decides which path updates are a reason to check the connections made
/// before them: connectivity coming back, or the interfaces in use changing
/// while online. Going offline is not one, as nothing could reconnect, and
/// neither is a change of the metered flags. The first update after starting
/// is only recorded, since it describes the path rather than a change of it.
struct NetworkPathChangeDetector: Sendable {
    private var previous: NetworkPathState?

    /// - Returns: whether `state` is such a change from the one before.
    mutating func ingest(_ state: NetworkPathState) -> Bool {
        defer { previous = state }
        guard let previous, state.isOnline else { return false }
        return !previous.isOnline || previous.interfaces != state.interfaces
    }
}

/// Tracks the current network path with `NWPathMonitor` and publishes it to
/// SwiftUI. `connectivity` mirrors the same values behind a lock.
@MainActor
@Perceptible
public final class NetworkMonitor {
    /// The path is satisfied. True until the first path update arrives.
    public private(set) var isOnline = true
    /// Cellular or Personal Hotspot.
    public private(set) var isExpensive = false
    /// Low Data Mode.
    public private(set) var isConstrained = false

    public var isMetered: Bool { isExpensive || isConstrained }

    /// Called when a path update may have broken the connections opened
    /// before it (see `NetworkPathChangeDetector`).
    @PerceptionIgnored var onPathChange: (@MainActor () -> Void)?

    public nonisolated let connectivity: any Connectivity
    @PerceptionIgnored private nonisolated let sharedConnectivity: LockedConnectivity
    @PerceptionIgnored private nonisolated let queue = DispatchQueue(
        label: "github.realtvop.aonsoku.network-monitor"
    )
    @PerceptionIgnored private let monitorsPaths: Bool
    @PerceptionIgnored private var monitor: NWPathMonitor?
    @PerceptionIgnored private var generation = UUID()

    public init() {
        let sharedConnectivity = LockedConnectivity(isOnline: true, isMetered: false)
        self.sharedConnectivity = sharedConnectivity
        connectivity = sharedConnectivity
        monitorsPaths = true
    }

    init(isOnline: Bool, isMetered: Bool) {
        let sharedConnectivity = LockedConnectivity(
            isOnline: isOnline,
            isMetered: isMetered
        )
        self.sharedConnectivity = sharedConnectivity
        connectivity = sharedConnectivity
        self.isOnline = isOnline
        isExpensive = isMetered
        monitorsPaths = false
    }

    /// Starts monitoring. Calling it again has no effect.
    public func start() {
        guard monitorsPaths else { return }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        let generation = UUID()
        self.generation = generation
        self.monitor = monitor
        let sharedConnectivity = sharedConnectivity
        let detector = LockedPathChangeDetector()
        monitor.pathUpdateHandler = { [weak self] path in
            let state = NetworkPathState(
                isOnline: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                interfaces: Set(path.availableInterfaces.map(\.type))
            )
            let changed = detector.ingest(state)
            sharedConnectivity.update(
                isOnline: state.isOnline,
                isMetered: state.isExpensive || state.isConstrained
            )
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.publish(state, mayHaveBrokenConnections: changed)
            }
        }
        monitor.start(queue: queue)
    }

    /// Publishes a path update, then tells `onPathChange` when it may have
    /// broken connections.
    func publish(_ state: NetworkPathState, mayHaveBrokenConnections: Bool) {
        isOnline = state.isOnline
        isExpensive = state.isExpensive
        isConstrained = state.isConstrained
        if mayHaveBrokenConnections { onPathChange?() }
    }

    public func stop() {
        generation = UUID()
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
    }
}

final class LockedPathChangeDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = NetworkPathChangeDetector()

    func ingest(_ state: NetworkPathState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return detector.ingest(state)
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
