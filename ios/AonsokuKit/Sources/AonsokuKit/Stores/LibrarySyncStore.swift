import Foundation
import Perception

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
@Perceptible
public final class LibrarySyncStore {
    public private(set) var phase = LibrarySyncPhase.idle
    public private(set) var lastSyncedAt: Date?
    /// Increments when synced data changes, so lists can reload.
    public private(set) var revision = 0

    @PerceptionIgnored public let library: LibraryService
    @PerceptionIgnored public let settings: SettingsStore
    @PerceptionIgnored public let connectivity: any Connectivity
    @PerceptionIgnored private var subscription: UUID?
    @PerceptionIgnored private var started = false
    @PerceptionIgnored private var revisionPending = false
    @PerceptionIgnored private var lastForegroundSyncAt: Date?
    @PerceptionIgnored private var syncCompleted: (@MainActor () -> Void)?
    @PerceptionIgnored private let operations: LibrarySyncOperations
    @PerceptionIgnored private let now: @Sendable () -> Date

    public init(library: LibraryService, settings: SettingsStore, connectivity: any Connectivity) {
        self.library = library
        self.settings = settings
        self.connectivity = connectivity
        operations = LibrarySyncOperations(library: library)
        now = { Date() }
    }

    init(
        library: LibraryService,
        settings: SettingsStore,
        connectivity: any Connectivity,
        operations: LibrarySyncOperations,
        now: @escaping @Sendable () -> Date
    ) {
        self.library = library
        self.settings = settings
        self.connectivity = connectivity
        self.operations = operations
        self.now = now
    }

    public var isSyncing: Bool { phase.isActive }

    func onSyncCompleted(_ handler: @escaping @MainActor () -> Void) {
        syncCompleted = handler
    }

    /// Subscribes to sync events and runs the startup sync. Call after
    /// sign-in.
    public func start() {
        guard !started else { return }
        started = true
        subscription = operations.subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }

        let availability = operations.availability()
        lastSyncedAt = availability.lastSyncedAt.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        }
        guard connectivity.isOnline, !connectivity.isMetered else { return }
        if availability.available {
            operations.syncIncremental(options())
        } else {
            operations.syncAll(options())
        }
    }

    /// Unsubscribes and cancels any sync (sign-out).
    public func stop() {
        if let subscription {
            operations.unsubscribe(subscription)
        }
        subscription = nil
        started = false
        revisionPending = false
        operations.cancel()
        phase = .idle
    }

    /// Full sync of every song (Settings "Sync now").
    public func syncNow() {
        guard connectivity.isOnline else { return }
        operations.syncAll(options())
    }

    /// Incremental sync (pull to refresh, settings changes).
    public func syncIncremental() {
        guard connectivity.isOnline else { return }
        operations.syncIncremental(options())
    }

    public func cancel() {
        operations.cancel()
        phase = .cancelled
    }

    /// Incremental sync when the app returns to the foreground, throttled.
    public func handleForeground() {
        guard connectivity.isOnline, !connectivity.isMetered, !isSyncing else { return }
        let reference = lastForegroundSyncAt ?? lastSyncedAt
        if let reference, now().timeIntervalSince(reference) <= 5 * 60 { return }
        lastForegroundSyncAt = now()
        operations.syncIncremental(options())
    }

    func handle(_ event: LibraryEvent) {
        switch event {
        case let .syncStateChanged(state):
            switch state.phase {
            case "done":
                phase = .done
                lastSyncedAt = now()
                lastForegroundSyncAt = lastSyncedAt
                syncCompleted?()
            case "cancelled":
                phase = .cancelled
            case "error":
                phase = .failed(state.message ?? "Library sync failed")
            case "coverArt":
                phase = .coverArt(
                    processed: state.processedItems,
                    total: state.totalItems
                )
            default:
                phase = state.isSyncing
                    ? .syncing(
                        tier: state.tier,
                        processed: state.processedItems,
                        total: state.totalItems
                    )
                    : .idle
            }
        case .dataChanged:
            guard !revisionPending else { return }
            revisionPending = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, revisionPending else { return }
                revisionPending = false
                revision += 1
            }
        }
    }

    private func options() -> LibrarySyncOptions {
        let cache = settings.settings.cache
        return LibrarySyncOptions(
            includeFullSongs: true,
            coverArt: cache.syncCoverArt
                ? LibrarySyncOptions.CoverArt(
                    concurrency: cache.coverArtConcurrency,
                    useAlbumCoverForSongs: settings.settings.playback.useAlbumCoverForSongs
                )
                : nil
        )
    }
}

struct LibrarySyncOperations: @unchecked Sendable {
    var availability: @Sendable () -> LibraryAvailability
    var subscribe: @Sendable (@escaping LibraryService.EventHandler) -> UUID
    var unsubscribe: @Sendable (UUID) -> Void
    var syncAll: @Sendable (LibrarySyncOptions) -> Void
    var syncIncremental: @Sendable (LibrarySyncOptions) -> Void
    var cancel: @Sendable () -> Void

    init(library: LibraryService) {
        availability = { library.availability() }
        subscribe = { library.subscribe($0) }
        unsubscribe = { library.unsubscribe($0) }
        syncAll = { library.syncAll(options: $0) }
        syncIncremental = { library.syncIncremental(options: $0) }
        cancel = { library.cancelSync() }
    }

    init(
        availability: @escaping @Sendable () -> LibraryAvailability,
        subscribe: @escaping @Sendable (@escaping LibraryService.EventHandler) -> UUID,
        unsubscribe: @escaping @Sendable (UUID) -> Void,
        syncAll: @escaping @Sendable (LibrarySyncOptions) -> Void,
        syncIncremental: @escaping @Sendable (LibrarySyncOptions) -> Void,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.availability = availability
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
        self.syncAll = syncAll
        self.syncIncremental = syncIncremental
        self.cancel = cancel
    }
}
