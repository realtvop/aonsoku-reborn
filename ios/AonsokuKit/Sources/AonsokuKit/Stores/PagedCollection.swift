import Foundation
import Perception

/// Loading state of a screen's data.
public enum LoadPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)

    public var isLoading: Bool { self == .loading }

    public var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// A list loaded page by page as the user scrolls. Views call
/// `loadIfNeeded()` when they appear, `loadMoreIfNeeded(currentItem:)` from
/// each row, and `refresh()` for pull to refresh.
@MainActor
@Perceptible
public final class PagedCollection<Item: Identifiable & Sendable> {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loadingMore
        case loaded
        case failed(String)
    }

    public typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> LibraryPage<Item>

    public private(set) var items: [Item] = []
    /// Total reported by the source; may exceed `items.count`.
    public private(set) var total = 0
    public private(set) var phase: Phase = .idle
    public private(set) var hasMore = false

    public let pageSize: Int

    @PerceptionIgnored private let fetch: Fetch
    @PerceptionIgnored private var task: Task<Void, Never>?
    @PerceptionIgnored private var generation = 0
    /// Rows fetched so far, counting duplicates dropped from `items`.
    @PerceptionIgnored private var nextOffset = 0
    @PerceptionIgnored private var seenIds = Set<Item.ID>()
    /// Rows from the end at which the next page starts loading.
    @PerceptionIgnored private let prefetchDistance = 20

    public init(pageSize: Int = 100, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    public var isEmpty: Bool { items.isEmpty }

    public var errorMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    /// True while the first page is loading and nothing is shown yet.
    public var isInitialLoading: Bool {
        items.isEmpty && (phase == .idle || phase == .loading)
    }

    public func loadIfNeeded() {
        guard phase == .idle else { return }
        reload()
    }

    /// Reloads from the first page. Current items stay visible until the
    /// first page arrives.
    public func reload() {
        task?.cancel()
        generation += 1
        let generation = generation
        phase = .loading
        task = Task { [weak self] in
            await self?.loadPage(offset: 0, generation: generation, replacing: true)
        }
    }

    /// Reloads and waits for the first page, for `.refreshable`.
    public func refresh() async {
        reload()
        await task?.value
    }

    /// Loads the next page when `currentItem` is near the end of the list.
    /// Pass nil to load the next page unconditionally.
    public func loadMoreIfNeeded(currentItem: Item?) {
        guard hasMore, phase == .loaded else { return }
        if let currentItem {
            let isNearEnd = items.suffix(prefetchDistance).contains { $0.id == currentItem.id }
            guard isNearEnd else { return }
        }
        phase = .loadingMore
        let generation = generation
        let offset = nextOffset
        task = Task { [weak self] in
            await self?.loadPage(offset: offset, generation: generation, replacing: false)
        }
    }

    /// Retries after a failure: the first page when nothing loaded,
    /// otherwise the next page.
    public func retry() {
        guard case .failed = phase else { return }
        if items.isEmpty {
            reload()
        } else {
            phase = .loaded
            loadMoreIfNeeded(currentItem: nil)
        }
    }

    /// Applies a local change, such as removing a deleted row, without
    /// reloading.
    public func update(_ body: (inout [Item]) -> Void) {
        body(&items)
        seenIds = Set(items.map(\.id))
    }

    private func loadPage(offset: Int, generation: Int, replacing: Bool) async {
        do {
            let page = try await fetch(offset, pageSize)
            guard generation == self.generation, !Task.isCancelled else { return }
            if replacing {
                items = []
                seenIds = []
            }
            var appended = items
            for item in page.items where seenIds.insert(item.id).inserted {
                appended.append(item)
            }
            items = appended
            nextOffset = offset + page.items.count
            total = max(page.total, items.count)
            hasMore = page.hasMore && !page.items.isEmpty
            phase = .loaded
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            if error is CancellationError { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
