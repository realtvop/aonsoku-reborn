import AonsokuKit
import SwiftUI

/// The user's playlists and those shared with them, most recently changed
/// first, with New Playlist at the top as in Apple Music.
struct PlaylistsListView: View {
    @State private var searchText = ""

    @Environment(Router.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SessionStore.self) private var session
    @Environment(Localizer.self) private var t

    var body: some View {
        List {
            if !isSearching, !playlists.playlists.isEmpty {
                NewPlaylistRow {
                    router.present(.createPlaylist(songs: []))
                }
                .themedRow(plain: true)
            }
            ForEach(filtered) { playlist in
                PlaylistRow(playlist: playlist)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if playlist.isOwned(by: session.account?.username) {
                            // Not a destructive role: the row stays until the
                            // deletion is confirmed.
                            Button {
                                router.playlistPendingDeletion = playlist
                            } label: {
                                Label(t("options.playlist.delete"), systemImage: "trash")
                            }
                            .tint(.red)
                            Button {
                                router.present(.editPlaylist(playlist))
                            } label: {
                                Label(t("options.playlist.edit"), systemImage: "pencil")
                            }
                        }
                    }
                    .themedRow(plain: true)
            }
        }
        .listStyle(.plain)
        .loadStates(playlists.phase, isEmpty: playlists.playlists.isEmpty) {
            Task { await playlists.reload() }
        } empty: {
            EmptyStateView(title: t("sidebar.emptyPlaylist"), systemImage: "music.note.list") {
                Button(t("options.playlist.create")) {
                    router.present(.createPlaylist(songs: []))
                }
                .buttonStyle(.glassProminent)
            }
        }
        .overlay {
            if isSearching, filtered.isEmpty, !playlists.playlists.isEmpty {
                EmptyStateView(title: t("options.playlist.notFound"), systemImage: "magnifyingglass")
            }
        }
        .offlineBanner()
        .themedBackground()
        .navigationTitle(t("sidebar.playlists"))
        .searchable(text: $searchText, prompt: Text(t("options.playlist.search")))
        .refreshable { await playlists.reload() }
        .task { await playlists.loadIfNeeded() }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    private var filtered: [Playlist] {
        guard isSearching else { return playlists.playlists }
        return playlists.playlists.filter { $0.name.localizedStandardContains(trimmedSearch) }
    }
}

/// The New Playlist row: a tinted plus where the cover would be.
struct NewPlaylistRow: View {
    let action: () -> Void

    @Environment(Localizer.self) private var t

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.fill.tertiary)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.tint)
                    }
                Text(t("options.playlist.create"))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A playlist in a list: cover, name, length and, for a playlist someone
/// else shared, its owner.
struct PlaylistRow: View {
    let playlist: Playlist

    @Environment(SessionStore.self) private var session
    @Environment(Localizer.self) private var t

    var body: some View {
        NavigationLink(value: AppRoute.playlist(id: playlist.id)) {
            HStack(spacing: 12) {
                ArtworkImage(id: playlist.coverArt, size: .small, cornerRadius: 6, placeholder: "music.note.list")
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(details)
                            .lineLimit(1)
                        PlaylistCacheBadge(playlistId: playlist.id)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            PlaylistMenuItems(playlist: playlist)
        }
    }

    private var details: String {
        let count = t("playlist.songCount", count: playlist.songCount)
        guard let owner = playlist.owner, !owner.isEmpty,
              !playlist.isOwned(by: session.account?.username)
        else { return count }
        return "\(count) · \(owner)"
    }
}
