import AonsokuKit
import SwiftUI

enum AppTab: Hashable {
    case home
    case library
    case search
}

/// Pushed destinations, shared by every tab's navigation stack.
enum AppRoute: Hashable {
    /// `preview` fills the header while the album loads.
    case album(id: String, preview: Album?)
    case artist(id: String, name: String)
    case playlist(id: String)
    case albums(AlbumListFilter)
    case songs(SongListQuery)
    case artists
    case playlists
    case favorites
    case genres
    case radios
    case downloads

    static func album(_ album: Album) -> AppRoute {
        .album(id: album.id, preview: album)
    }
}

/// Sheets any screen can present. They appear over whatever is on top,
/// including Now Playing.
enum GlobalSheet: Identifiable {
    case songInfo(Song)
    case addToPlaylist([Song])
    case createPlaylist(songs: [Song])
    case editPlaylist(Playlist)
    case radioEditor(RadioStation?)
    /// Cross-device playback: this device, devices to control and playback
    /// to continue here.
    case devices
    /// Lyrics choice, offset and visibility for the playing song.
    case lyricsSettings

    var id: String {
        switch self {
        case let .songInfo(song): "songInfo:\(song.id)"
        case let .addToPlaylist(songs): "addToPlaylist:\(songs.map(\.id).joined(separator: ","))"
        case .createPlaylist: "createPlaylist"
        case let .editPlaylist(playlist): "editPlaylist:\(playlist.id)"
        case let .radioEditor(station): "radioEditor:\(station?.id ?? "new")"
        case .devices: "devices"
        case .lyricsSettings: "lyricsSettings"
        }
    }
}

/// Pages of the account sheet's settings.
enum SettingsPage: Hashable {
    case server
    case appearance
    case language
    case playback
    case lyrics
    case content
    case storage
    case cacheManager
    case crossDevice
    case privacy
    case about
}

/// Playlist entries waiting for the user to confirm removing them.
struct PlaylistSongRemoval: Equatable {
    let playlistId: String
    /// Positions in the playlist, which may hold a song more than once.
    let indexes: [Int]
}

/// Navigation and presentation state for the signed-in interface.
@MainActor
@Observable
final class Router {
    /// What is presented over the tabs. Sheets and alerts attach to the
    /// topmost layer, because a view that already presents cannot present
    /// again.
    enum Layer {
        case root
        case account
        case nowPlaying
    }

    var selectedTab: AppTab = .home
    var homePath: [AppRoute] = []
    var libraryPath: [AppRoute] = []
    var searchPath: [AppRoute] = []
    /// Settings pages pushed in the account sheet.
    var accountPath: [SettingsPage] = []
    var isNowPlayingPresented = false
    var isAccountPresented = false
    var sheet: GlobalSheet?
    /// A playlist waiting for the user to confirm its deletion.
    var playlistPendingDeletion: Playlist?
    var playlistSongRemoval: PlaylistSongRemoval?

    var topLayer: Layer {
        if isNowPlayingPresented { return .nowPlaying }
        if isAccountPresented { return .account }
        return .root
    }

    /// Pushes `route` on the selected tab, closing anything presented.
    func navigate(to route: AppRoute) {
        sheet = nil
        isNowPlayingPresented = false
        isAccountPresented = false
        switch selectedTab {
        case .home: homePath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    func presentNowPlaying() {
        sheet = nil
        isAccountPresented = false
        isNowPlayingPresented = true
    }

    func present(_ sheet: GlobalSheet) {
        self.sheet = sheet
    }

    /// Opens the account sheet, at `page` when given.
    func openSettings(_ page: SettingsPage? = nil) {
        sheet = nil
        isNowPlayingPresented = false
        accountPath = page.map { [$0] } ?? []
        isAccountPresented = true
    }

    /// Pops every tab back to before the first route matching `isRemoved`,
    /// after the item it shows was deleted.
    func dismissRoutes(where isRemoved: (AppRoute) -> Bool) {
        func truncate(_ path: inout [AppRoute]) {
            if let index = path.firstIndex(where: isRemoved) {
                path.removeSubrange(index...)
            }
        }
        truncate(&homePath)
        truncate(&libraryPath)
        truncate(&searchPath)
    }

    /// Selecting the selected tab again returns it to its root.
    func select(_ tab: AppTab) {
        if tab == selectedTab {
            switch tab {
            case .home: homePath.removeAll()
            case .library: libraryPath.removeAll()
            case .search: searchPath.removeAll()
            }
        }
        selectedTab = tab
    }

    /// Clears everything on sign-out.
    func reset() {
        sheet = nil
        playlistPendingDeletion = nil
        playlistSongRemoval = nil
        isNowPlayingPresented = false
        isAccountPresented = false
        homePath.removeAll()
        libraryPath.removeAll()
        searchPath.removeAll()
        accountPath.removeAll()
        selectedTab = .home
    }
}

// MARK: - Destinations

extension View {
    /// Registers the shared routes on a navigation stack.
    func appDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteView(route: route)
        }
    }

    /// Presents the global sheet and the confirmation dialogs when `layer`
    /// is the topmost one.
    func globalPresentations(_ layer: Router.Layer) -> some View {
        modifier(GlobalPresentationsModifier(layer: layer))
    }
}

private struct RouteView: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case let .album(id, preview):
            AlbumDetailView(albumId: id, preview: preview)
        case let .artist(id, name):
            ArtistDetailView(artistId: id, name: name)
        case let .playlist(id):
            PlaylistDetailView(playlistId: id)
        case let .albums(filter):
            AlbumsListView(filter: filter)
        case let .songs(query):
            SongsListView(query: query)
        case .artists:
            ArtistsListView()
        case .playlists:
            PlaylistsListView()
        case .favorites:
            FavoritesView()
        case .genres:
            GenresView()
        case .radios:
            RadiosView()
        case .downloads:
            DownloadsView()
        }
    }
}

private struct GlobalPresentationsModifier: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    let layer: Router.Layer

    func body(content: Content) -> some View {
        content
            .sheet(item: sheet) { sheet in
                GlobalSheetView(sheet: sheet)
            }
            .alert(t("queue.replacementConfirmation.title"), isPresented: isAskingReplacement) {
                Button(t("queue.replacementConfirmation.replace"), role: .destructive) {
                    player.resolveReplacement(.replace)
                }
                Button(t("queue.replacementConfirmation.playNext")) {
                    player.resolveReplacement(.playNext)
                }
                Button(t("generic.cancel"), role: .cancel) {
                    player.resolveReplacement(.cancel)
                }
            } message: {
                Text(t("queue.replacementConfirmation.description"))
            }
            .alert(
                t("playlist.form.delete.title"),
                isPresented: isConfirmingDeletion,
                presenting: router.playlistPendingDeletion
            ) { playlist in
                Button(t("options.playlist.delete"), role: .destructive) {
                    delete(playlist)
                }
                Button(t("generic.cancel"), role: .cancel) {}
            } message: { _ in
                Text(t("playlist.form.delete.description"))
            }
            .alert(
                t("playlist.form.removeSong.title", count: router.playlistSongRemoval?.indexes.count ?? 1),
                isPresented: isConfirmingSongRemoval,
                presenting: router.playlistSongRemoval
            ) { removal in
                Button(t("options.playlist.removeSong"), role: .destructive) {
                    remove(removal)
                }
                Button(t("generic.cancel"), role: .cancel) {}
            } message: { _ in
                Text(t("playlist.form.removeSong.description"))
            }
    }

    private func remove(_ removal: PlaylistSongRemoval) {
        router.playlistSongRemoval = nil
        let isSingle = removal.indexes.count == 1
        Task {
            do {
                try await playlists.remove(indexes: removal.indexes, from: removal.playlistId)
                toasts.success(
                    isSingle
                        ? "playlist.form.removeSong.toast.success_one"
                        : "playlist.form.removeSong.toast.success_other"
                )
            } catch {
                toasts.show(
                    error: error,
                    fallbackKey: isSingle
                        ? "playlist.form.removeSong.toast.error_one"
                        : "playlist.form.removeSong.toast.error_other"
                )
            }
        }
    }

    private func delete(_ playlist: Playlist) {
        router.playlistPendingDeletion = nil
        Task {
            do {
                try await playlists.delete(playlist.id)
                router.dismissRoutes { $0 == .playlist(id: playlist.id) }
                toasts.success("playlist.form.delete.toast.success")
            } catch {
                toasts.show(error: error, fallbackKey: "playlist.form.delete.toast.error")
            }
        }
    }

    private var isTop: Bool { router.topLayer == layer }

    private var sheet: Binding<GlobalSheet?> {
        Binding(
            get: { isTop ? router.sheet : nil },
            set: { if isTop { router.sheet = $0 } }
        )
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { isTop && router.sheet == nil && router.playlistPendingDeletion != nil },
            set: { if !$0, isTop { router.playlistPendingDeletion = nil } }
        )
    }

    private var isConfirmingSongRemoval: Binding<Bool> {
        Binding(
            get: { isTop && router.sheet == nil && router.playlistSongRemoval != nil },
            set: { if !$0, isTop { router.playlistSongRemoval = nil } }
        )
    }

    private var isAskingReplacement: Binding<Bool> {
        Binding(
            get: { isTop && router.sheet == nil && player.pendingReplacement != nil },
            // The buttons resolve the request; dismissal alone keeps it.
            set: { _ in }
        )
    }
}

private struct GlobalSheetView: View {
    let sheet: GlobalSheet

    var body: some View {
        switch sheet {
        case let .songInfo(song):
            SongInfoView(song: song)
        case let .addToPlaylist(songs):
            AddToPlaylistView(songs: songs)
        case let .createPlaylist(songs):
            PlaylistEditorView(mode: .create(songs: songs))
        case let .editPlaylist(playlist):
            PlaylistEditorView(mode: .edit(playlist))
        case let .radioEditor(station):
            RadioEditorView(station: station)
        case .devices:
            DevicesView()
        case .lyricsSettings:
            LyricsSettingsView()
        }
    }
}

// MARK: - Titles

extension AlbumListFilter {
    func title(_ t: Localizer) -> String {
        switch self {
        case .alphabeticalByName: t("album.list.filter.name")
        case .alphabeticalByArtist: t("album.list.filter.artist")
        case .recentlyAdded: t("album.list.filter.recentlyAdded")
        case .recentlyPlayed: t("album.list.filter.recentlyPlayed")
        case .mostPlayed: t("album.list.filter.mostPlayed")
        case .random: t("album.list.filter.random")
        case .favorites: t("album.list.filter.favorites")
        case .byYear: t("album.list.filter.releaseYear")
        case let .byGenre(genre): genre
        case .discography: t("album.list.filter.discography")
        case let .search(query): query
        }
    }
}
