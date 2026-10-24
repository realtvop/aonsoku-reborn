import AonsokuKit
import SwiftUI

/// The Search tab. With an empty field it shows the biggest genres to
/// browse; typing searches artists, albums and songs in sections captioned
/// like the web's mobile search, each linking to its full results.
struct SearchView: View {
    @State private var text = ""
    /// `text` once typing pauses.
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var phase = LoadPhase.idle

    @Environment(AppModel.self) private var app
    @Environment(NetworkMonitor.self) private var network
    @Environment(Localizer.self) private var t

    var body: some View {
        Group {
            if Self.isSearchable(query) {
                resultsList
            } else {
                BrowseGenres()
            }
        }
        .offlineBanner()
        .themedBackground()
        .navigationTitle(t("sidebar.miniSearch"))
        .searchable(text: $text, prompt: Text(t("command.inputPlaceholder")))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            query = trimmedText
        }
        .task(id: trimmedText) {
            // Waits for typing to pause; clearing the field is immediate.
            guard !trimmedText.isEmpty else {
                query = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            query = trimmedText
        }
        .task(id: query) {
            await search()
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Searches start at three bytes, as on the web, so a single CJK
    /// character searches but a single Latin letter does not.
    static func isSearchable(_ query: String) -> Bool {
        query.utf8.count >= 3
    }

    private var resultsList: some View {
        List {
            if let results {
                // Artists first, as in Apple Music: a name usually means
                // the artist.
                if !results.artists.isEmpty {
                    Section {
                        ForEach(results.artists) { artist in
                            ArtistRow(artist: artist)
                                .themedRow(plain: true)
                        }
                    } header: {
                        resultsHeader(t("sidebar.artists"))
                    }
                }
                if !results.albums.isEmpty {
                    Section {
                        ForEach(results.albums) { album in
                            AlbumResultRow(album: album)
                                .themedRow(plain: true)
                        }
                    } header: {
                        resultsHeader(t("sidebar.albums"), route: .albums(.search(query)))
                    }
                }
                if !results.songs.isEmpty {
                    Section {
                        ForEach(results.songs) { song in
                            SongResultRow(song: song)
                                .themedRow(plain: true)
                        }
                    } header: {
                        resultsHeader(t("sidebar.songs"), route: .songs(SongListQuery(search: query)))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .loadStates(phase, isEmpty: results?.isEmpty ?? true) {
            Task { await search() }
        } empty: {
            EmptyStateView(title: t("command.noResults"), systemImage: "magnifyingglass")
        }
    }

    private func resultsHeader(_ title: String, route: AppRoute? = nil) -> some View {
        CaptionHeader(title: title) {
            if let route {
                NavigationLink(value: route) {
                    Text(t("generic.seeMore"))
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .textCase(nil)
    }

    private func search() async {
        let query = query
        guard Self.isSearchable(query) else {
            results = nil
            phase = .idle
            return
        }
        // Earlier results stay until the new ones arrive.
        phase = .loading
        do {
            let found = try await app.repository.search(query, limit: 6)
            guard !Task.isCancelled else { return }
            results = found
            phase = .loaded
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            results = nil
            phase = .failed(network.isOnline ? error.localizedDescription : t("offline.searchUnavailable"))
        }
    }
}

/// The largest genres as cards, with the full list a tap away.
private struct BrowseGenres: View {
    @State private var genres: [Genre]?

    @Environment(AppModel.self) private var app
    @Environment(Localizer.self) private var t

    var body: some View {
        ScrollView {
            if let genres, !genres.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: t("table.columns.genres"), route: .genres)
                        .pageMargins()
                    TileGrid(minimumWidth: 160) {
                        ForEach(genres) { genre in
                            GenreLink(genre: genre)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if let genres, genres.isEmpty {
                EmptyStateView(
                    title: t("sidebar.miniSearch"),
                    systemImage: "magnifyingglass",
                    description: t("native.search.description")
                )
            }
        }
        .task {
            guard genres == nil else { return }
            let all = (try? await app.repository.genres()) ?? []
            genres = Array(
                all.sorted {
                    $0.albumCount != $1.albumCount
                        ? $0.albumCount > $1.albumCount
                        : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                .prefix(12)
            )
        }
    }
}

/// An album in the results: cover, title, and "Album · Artist".
private struct AlbumResultRow: View {
    let album: Album

    @Environment(Localizer.self) private var t

    var body: some View {
        NavigationLink(value: AppRoute.album(album)) {
            HStack(spacing: 12) {
                ArtworkImage(id: album.coverArt, size: .small, cornerRadius: Layout.rowArtworkRadius)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(album.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if album.explicitStatus == .explicit {
                            ExplicitBadge()
                        }
                    }
                    HStack(spacing: 4) {
                        Text("\(t("album.headline")) · \(album.artistLine)")
                            .lineLimit(1)
                        AlbumCacheBadge(albumId: album.id)
                    }
                    .font(.footnote)
                    .foregroundStyle(ThemeColor.mutedForeground)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowSeparator(.hidden)
        .contextMenu {
            AlbumMenuItems(album: album)
        }
    }
}

/// A song in the results, which plays on its own when tapped.
private struct SongResultRow: View {
    let song: Song

    @Environment(PlayerStore.self) private var player

    var body: some View {
        SongRow(song: song) {
            player.play(song: song)
        }
    }
}
