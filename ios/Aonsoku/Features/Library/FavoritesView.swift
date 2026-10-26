import AonsokuKit
import Perception
import SwiftUI

/// Liked songs, albums and artists, one kind at a time under a segmented
/// control that stays below the navigation bar.
struct FavoritesView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case songs
        case albums
        case artists

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .songs: "sidebar.songs"
            case .albums: "sidebar.albums"
            case .artists: "sidebar.artists"
            }
        }
    }

    @State private var kind = Kind.songs

    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            Group {
                switch kind {
                case .songs: FavoriteSongs()
                case .albums: FavoriteAlbums()
                case .artists: FavoriteArtists()
                }
            }
            .safeAreaBar(edge: .top) {
                Picker(t("favorites.headline"), selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        WithPerceptionTracking {
                            Text(t(kind.titleKey)).tag(kind)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .pageMargins()
                .padding(.bottom, 8)
            }
            .offlineBanner()
            .themedBackground()
            .navigationTitle(t("favorites.headline"))
            // A large title would sit under the blur of the bar holding the
            // picker, so the title stays inline.
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct FavoriteSongs: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerStore.self) private var player
    @Environment(FavoritesStore.self) private var favorites
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            QueriedCollection(query: SongListQuery(scope: .favorites)) { repository, query, offset, limit in
                WithPerceptionTracking {
                    try await repository.songs(query, offset: offset, limit: limit)
                }
            } content: { collection in
                PagedSongList(collection: collection) { index in
                    player.play(collection.items, startingAt: index, sourceName: t("favorites.headline"))
                } header: {
                    PlayShuffleButtons {
                        playAll(collection, shuffle: false)
                    } shuffle: {
                        playAll(collection, shuffle: true)
                    }
                    .padding(.vertical, 8)
                } empty: {
                    EmptyStateView(title: t("favorites.noSongs"), systemImage: "heart")
                }
                .navigationSubtitle(collection.isEmpty ? "" : t("favorites.songCount", count: collection.total))
                .reloadsOnChange(of: favorites.revision, collection)
            }
        }
    }

    /// Plays every favorite, fetching those not loaded yet.
    private func playAll(_ collection: PagedCollection<Song>, shuffle: Bool) {
        let name = t("favorites.headline")
        guard collection.hasMore else {
            player.play(collection.items, shuffle: shuffle, sourceName: name)
            return
        }
        let repository = app.repository
        let total = collection.total
        Task {
            do {
                let songs = try await repository.songs(SongListQuery(scope: .favorites), offset: 0, limit: total).items
                player.play(songs, shuffle: shuffle, sourceName: name)
            } catch {
                toasts.show(error: error)
            }
        }
    }
}

private struct FavoriteAlbums: View {
    @Environment(FavoritesStore.self) private var favorites
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            QueriedCollection(query: AlbumListFilter.favorites) { repository, filter, offset, limit in
                WithPerceptionTracking {
                    try await repository.albums(filter, offset: offset, limit: limit)
                }
            } content: { collection in
                ScrollView {
                    AlbumGrid(collection: collection)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                }
                .pagedStates(collection) {
                    EmptyStateView(title: t("native.favorites.noAlbums"), systemImage: "heart")
                }
                .refreshable { await collection.refresh() }
                .navigationSubtitle(collection.isEmpty ? "" : t("artist.info.albumsCount", count: collection.total))
                .reloadsOnChange(of: favorites.revision, collection)
            }
        }
    }
}

private struct FavoriteArtists: View {
    @Environment(FavoritesStore.self) private var favorites
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            QueriedCollection(query: "starred") { repository, _, offset, limit in
                WithPerceptionTracking {
                    try await repository.artists(starredOnly: true, offset: offset, limit: limit)
                }
            } content: { collection in
                PagedArtistList(collection: collection) {
                    EmptyStateView(title: t("native.favorites.noArtists"), systemImage: "heart")
                }
                .navigationSubtitle("")
                .reloadsOnChange(of: favorites.revision, collection)
            }
        }
    }
}

extension View {
    /// Reloads `collection` when `value` changes while it is still on its
    /// first page, so a like or unlike shows without losing a deep scroll
    /// position.
    func reloadsOnChange<Value: Equatable, Item: Identifiable & Sendable>(
        of value: Value,
        _ collection: PagedCollection<Item>
    ) -> some View {
        onChange(of: value) {
            guard collection.items.count <= collection.pageSize else { return }
            collection.reload()
        }
    }
}
