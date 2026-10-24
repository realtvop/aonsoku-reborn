import AonsokuKit
import SwiftUI

/// Every artist by name, as round portraits in a list, like the web's
/// mobile artist list.
struct ArtistsListView: View {
    @State private var searchText = ""

    @Environment(Localizer.self) private var t

    var body: some View {
        QueriedCollection(query: trimmedSearch, debounce: isSearching ? .milliseconds(300) : .zero) { repository, search, offset, limit in
            try await repository.artists(search: search, offset: offset, limit: limit)
        } content: { collection in
            PagedArtistList(collection: collection) {
                if isSearching {
                    EmptyStateView(title: t("command.noResults"), systemImage: "magnifyingglass")
                } else {
                    EmptyStateView(title: t("native.artists.empty"), systemImage: "music.mic")
                }
            }
        }
        .offlineBanner()
        .themedBackground()
        .navigationTitle(t("sidebar.artists"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text(t("native.artists.search")))
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }
}

/// A plain list of artists that loads the next page as the end comes into
/// view. Shared by Artists and Favorites.
struct PagedArtistList<Empty: View>: View {
    let collection: PagedCollection<Artist>
    @ViewBuilder let empty: Empty

    var body: some View {
        List {
            ForEach(collection.items) { artist in
                ArtistRow(artist: artist)
                    .onAppear { collection.loadMoreIfNeeded(currentItem: artist) }
                    .themedRow(plain: true)
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

/// An artist in a list: portrait, name and number of albums.
struct ArtistRow: View {
    let artist: Artist

    @Environment(Localizer.self) private var t

    var body: some View {
        NavigationLink(value: AppRoute.artist(id: artist.id, name: artist.name)) {
            HStack(spacing: 12) {
                ArtworkImage(id: artist.coverArt, size: .small, isCircular: true, placeholder: "music.mic")
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artist.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if artist.albumCount > 0 {
                        Text(t("artist.info.albumsCount", count: artist.albumCount))
                            .font(.footnote)
                            .foregroundStyle(ThemeColor.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }
        }
        .listRowSeparator(.hidden)
        .compactRowInsets()
        .contextMenu {
            ArtistMenuItems(artist: artist)
        }
    }
}
