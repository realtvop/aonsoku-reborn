import AonsokuKit
import Perception
import SwiftUI

/// Owns a paged list for `query` and replaces it when the query changes.
/// The current results stay on screen until the new query's first page
/// arrives, so typing or changing a filter never flashes an empty list.
/// Returning to the page keeps the loaded list. When a library sync
/// finishes, a list still on its first page reloads; a longer one keeps
/// its place.
struct QueriedCollection<Query: Hashable & Sendable, Item: Identifiable & Sendable, Content: View>: View {
    let query: Query
    var pageSize = 100
    /// Waits this long after a change before loading, for search fields.
    var debounce: Duration = .zero
    let fetch: @Sendable (LibraryRepository, Query, _ offset: Int, _ limit: Int) async throws -> LibraryPage<Item>
    @ViewBuilder let content: (PagedCollection<Item>) -> Content

    @Environment(AppModel.self) private var app
    @Environment(LibrarySyncStore.self) private var sync
    @State private var collection: PagedCollection<Item>?
    @State private var loadedQuery: Query?

    var body: some View {
        WithPerceptionTracking {
            Group {
                if let collection {
                    content(collection)
                } else {
                    LoadingStateView()
                }
            }
            .task(id: query) { await load() }
            .onChange(of: sync.revision) {
                guard let collection, collection.items.count <= pageSize else { return }
                collection.reload()
            }
        }
    }

    private func load() async {
        guard collection == nil || query != loadedQuery else { return }
        let repository = app.repository
        let query = query
        let fetch = fetch
        let next = PagedCollection<Item>(pageSize: pageSize) { offset, limit in
            try await fetch(repository, query, offset, limit)
        }
        guard collection != nil else {
            collection = next
            loadedQuery = query
            next.loadIfNeeded()
            return
        }
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
        }
        guard !Task.isCancelled else { return }
        await next.refresh()
        guard !Task.isCancelled else { return }
        collection = next
        loadedQuery = query
    }
}
