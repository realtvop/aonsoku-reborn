import Foundation
import Observation

/// Library sync progress as shown in Settings and Library.
public enum LibrarySyncPhase: Hashable, Sendable {
    case idle
    /// Metadata tier `t1`, `t2` or `t3`.
    case syncing(tier: String?, processed: Int, total: Int)
    case coverArt(processed: Int, total: Int)
    case done
    case cancelled
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .syncing, .coverArt: true
        default: false
        }
    }

    /// 0...1 when the total is known.
    public var fraction: Double? {
        switch self {
        case let .syncing(_, processed, total), let .coverArt(processed, total):
            total > 0 ? min(Double(processed) / Double(total), 1) : nil
        default:
            nil
        }
    }
}

/// Runs library sync at the moments the web app does: a full sync once per
/// session at start, an incremental sync on foreground (at most every five
/// minutes), and on demand. Skips automatic syncs offline or on metered
/// networks.
@MainActor
@Observable
public final class LibrarySyncStore {
    public private(set) var phase = LibrarySyncPhase.idle
    public private(set) var lastSyncedAt: Date?
    /// Increments when synced data changes, so lists can reload.
    public private(set) var revision = 0

    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public let connectivity: any Connectivity

    public init(library: LibraryService, settings: SettingsStore, connectivity: any Connectivity) {
        self.library = library
        self.settings = settings
        self.connectivity = connectivity
    }

    public var isSyncing: Bool { phase.isActive }

    /// Subscribes to sync events and runs the startup sync. Call after
    /// sign-in.
    public func start() {}

    /// Unsubscribes and cancels any sync (sign-out).
    public func stop() {}

    /// Full sync of every song (Settings "Sync now").
    public func syncNow() {}

    /// Incremental sync (pull to refresh, settings changes).
    public func syncIncremental() {}

    public func cancel() {}

    /// Incremental sync when the app returns to the foreground, throttled.
    public func handleForeground() {}
}
