import AonsokuKit
import Perception
import SwiftUI

/// Songs in a list: the whole library, or one artist's or genre's. Search
/// and the sort menu refine it; Play and Shuffle start it all.
struct SongsListView: View {
    @State private var query: SongListQuery
    @State private var searchText: String

    @Environment(AppModel.self) private var app
    @Environment(PlayerStore.self) private var player
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    init(query: SongListQuery) {
        _query = State(initialValue: query)
        _searchText = State(initialValue: query.search)
    }

    var body: some View {
        WithPerceptionTracking {
            QueriedCollection(query: effectiveQuery, debounce: isSearching ? .milliseconds(300) : .zero) { repository, query, offset, limit in
                WithPerceptionTracking {
                    try await repository.songs(query, offset: offset, limit: limit)
                }
            } content: { collection in
                PagedSongList(collection: collection) { index in
                    player.play(collection.items, startingAt: index, source: source, sourceName: title)
                } header: {
                    PlayShuffleButtons {
                        player.play(collection.items, source: source, sourceName: title)
                    } shuffle: {
                        shuffle(collection)
                    }
                    .padding(.vertical, 8)
                } empty: {
                    if isSearching {
                        EmptyStateView(title: t("command.noResults"), systemImage: "magnifyingglass")
                    } else {
                        EmptyStateView(title: t("native.songs.empty"), systemImage: "music.note")
                    }
                }
                .navigationSubtitle(collection.isEmpty ? "" : t("playlist.songCount", count: collection.total))
            }
            .offlineBanner()
            .themedBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: Text(t("songs.list.search.placeholder")))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    WithPerceptionTracking {
                        sortMenu
                    }
                }
            }
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var effectiveQuery: SongListQuery {
        var effective = query
        effective.search = trimmedSearch
        return effective
    }

    private var title: String {
        switch query.scope {
        case .all, .album: t("sidebar.songs")
        case .favorites: t("favorites.headline")
        case let .artist(_, name): t("songs.list.byArtist", ["artist": name])
        case let .genre(genre): genre
        }
    }

    private var source: QueueSource? {
        switch query.scope {
        case let .artist(id, _): .artist(id)
        case let .genre(genre): .genre(genre)
        case let .album(id): .album(id)
        case .all, .favorites: nil
        }
    }

    /// Artist and genre lists can widen to the whole library, as on the web.
    private var isFiltered: Bool {
        switch query.scope {
        case .artist, .genre: true
        case .all, .album, .favorites: false
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(t("native.sort.label"), selection: sort) {
                ForEach(SongSort.allCases, id: \.self) { sort in
                    WithPerceptionTracking {
                        Text(t(sort.labelKey)).tag(sort)
                    }
                }
            }
            .pickerStyle(.inline)
            Picker(t("native.sort.order"), selection: $query.ascending) {
                Label(t("table.sort.asc"), systemImage: "arrow.up").tag(true)
                Label(t("table.sort.desc"), systemImage: "arrow.down").tag(false)
            }
            .pickerStyle(.inline)
            if isFiltered {
                Button(t("songs.list.filter.clear"), systemImage: "line.3.horizontal.decrease.circle") {
                    query.scope = .all
                }
            }
        } label: {
            Label(t("native.sort.label"), systemImage: "arrow.up.arrow.down")
        }
    }

    /// Picking an order also picks its natural direction: newest first for
    /// Last Added, A to Z for the rest.
    private var sort: Binding<SongSort> {
        Binding(
            get: { query.sort },
            set: { sort in
                query.sort = sort
                query.ascending = sort != .recentlyAdded
            }
        )
    }

    /// Shuffles everything the list holds, not only the pages loaded so far.
    /// The whole library or a genre shuffles a random sample, as the server's
    /// random songs are capped at 500.
    private func shuffle(_ collection: PagedCollection<Song>) {
        guard collection.hasMore else {
            player.play(collection.items, shuffle: true, source: source, sourceName: title)
            return
        }
        let repository = app.repository
        let query = effectiveQuery
        let total = collection.total
        let source = source
        let title = title
        Task {
            do {
                let songs: [Song]
                switch query.scope {
                case .all where query.search.isEmpty:
                    songs = try await repository.randomSongs(size: 500)
                case let .genre(genre) where query.search.isEmpty:
                    songs = try await repository.randomSongs(size: 500, genre: genre)
                default:
                    songs = try await repository.songs(query, offset: 0, limit: max(total, 1)).items
                }
                player.play(songs, shuffle: true, source: source, sourceName: title)
            } catch {
                toasts.show(error: error)
            }
        }
    }
}

/// A plain list of songs under a header, loading the next page as the end
/// comes into view. Shared by the song list and Favorites.
struct PagedSongList<Header: View, Empty: View>: View {
    let collection: PagedCollection<Song>
    let play: (_ index: Int) -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let empty: Empty

    var body: some View {
        WithPerceptionTracking {
            List {
                if !collection.isEmpty {
                    header
                        .listRowSeparator(.hidden)
                        .themedRow(plain: true)
                }
                ForEach(Array(collection.items.enumerated()), id: \.element.id) { index, song in
                    WithPerceptionTracking {
                        SongRow(
                            song: song,
                            isFirst: index == 0,
                            isLast: index == collection.items.count - 1 && !collection.hasMore
                        ) { play(index) }
                            .onAppear { collection.loadMoreIfNeeded(currentItem: song) }
                            .themedRow(plain: true)
                    }
                }
                if collection.phase == .loadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                        .themedRow(plain: true)
                }
            }
            .listStyle(.plain)
            .pagedStates(collection) { empty }
            .refreshable { await collection.refresh() }
        }
    }
}
