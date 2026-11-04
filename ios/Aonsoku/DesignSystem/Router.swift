import AonsokuKit
import Perception
import SwiftUI

enum AppTab: Hashable {
    case home
    case library
    case search
}

/// How the signed-in interface keeps its navigation stacks.
enum NavigationStyle {
    /// One stack per tab, with Now Playing and the account sheet presented
    /// over them (iOS).
    case tabs
    /// One stack per sidebar section; Now Playing is an inspector beside
    /// the content and Settings a window of its own (macOS).
    case sidebar
}

/// A destination in the Mac sidebar. Each section keeps a stack of its own.
enum SidebarSection: Hashable {
    case home
    case search
    case albums
    case artists
    case songs
    case playlists
    case favorites
    case genres
    case radios
    case downloads
    /// One of the user's playlists, from the sidebar's playlist list.
    case playlist(id: String)
    /// An album or playlist pinned to Home.
    case pinned(PinnedItem)

    /// A stable text form, for restoring the selection.
    var storageKey: String {
        switch self {
        case .home: "home"
        case .search: "search"
        case .albums: "albums"
        case .artists: "artists"
        case .songs: "songs"
        case .playlists: "playlists"
        case .favorites: "favorites"
        case .genres: "genres"
        case .radios: "radios"
        case .downloads: "downloads"
        case let .playlist(id): "playlist:\(id)"
        case let .pinned(item): "pinned:\(item.kind.rawValue):\(item.itemId)"
        }
    }

    init?(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "home": self = .home
        case "search": self = .search
        case "albums": self = .albums
        case "artists": self = .artists
        case "songs": self = .songs
        case "playlists": self = .playlists
        case "favorites": self = .favorites
        case "genres": self = .genres
        case "radios": self = .radios
        case "downloads": self = .downloads
        case "playlist" where parts.count == 2: self = .playlist(id: parts[1])
        case "pinned" where parts.count == 3:
            guard let kind = PinnedItem.Kind(rawValue: parts[1]) else { return nil }
            self = .pinned(PinnedItem(itemId: parts[2], kind: kind))
        default: return nil
        }
    }
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
@Perceptible
final class Router {
    let style: NavigationStyle

    init(style: NavigationStyle = .tabs) {
        self.style = style
    }

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
    /// The search field's text. Search reads it; on a Mac the window's
    /// toolbar field writes it from any section.
    var searchText = ""
    /// Counts searches submitted with Return, which skip the typing pause.
    private(set) var searchSubmissions = 0
    /// Counts requests to put the cursor in the search field (Find).
    private(set) var searchFocusRequests = 0

    // Sidebar navigation (`style == .sidebar`).
    var section: SidebarSection = .home
    private(set) var sectionPaths: [SidebarSection: [AppRoute]] = [:]
    /// Pages left with Back, newest last, for Forward.
    private(set) var forwardPaths: [SidebarSection: [AppRoute]] = [:]
    /// The settings page a Settings window shows.
    var settingsPage: SettingsPage = .server
    /// Opens Settings in a window of its own instead of the account sheet.
    @PerceptionIgnored var settingsWindowOpener: (() -> Void)?
    /// A playlist waiting for the user to confirm its deletion.
    var playlistPendingDeletion: Playlist?
    var playlistSongRemoval: PlaylistSongRemoval?

    var topLayer: Layer {
        // A sidebar's Now Playing is an inspector in the window, not a layer.
        if isNowPlayingPresented, style == .tabs { return .nowPlaying }
        if isAccountPresented { return .account }
        return .root
    }

    /// Pushes `route` on the selected tab or section, closing what is
    /// presented over it.
    func navigate(to route: AppRoute) {
        sheet = nil
        isAccountPresented = false
        switch style {
        case .tabs:
            isNowPlayingPresented = false
            switch selectedTab {
            case .home: homePath.append(route)
            case .library: libraryPath.append(route)
            case .search: searchPath.append(route)
            }
        case .sidebar:
            sectionPaths[section, default: []].append(route)
            forwardPaths[section] = nil
        }
    }

    // MARK: Sidebar

    /// The selected section's stack, for its `NavigationStack`. Popping
    /// through it, as the stack's own gestures do, keeps the pages for
    /// Forward; pushing anything else forgets them.
    var sectionPath: Binding<[AppRoute]> {
        let section = section
        return Binding(
            get: { self.sectionPaths[section] ?? [] },
            set: { self.setPath($0, in: section) }
        )
    }

    var canGoBack: Bool { !(sectionPaths[section] ?? []).isEmpty }
    var canGoForward: Bool { !(forwardPaths[section] ?? []).isEmpty }

    func goBack() {
        guard var path = sectionPaths[section], let last = path.popLast() else { return }
        sectionPaths[section] = path
        forwardPaths[section, default: []].append(last)
    }

    func goForward() {
        guard var forward = forwardPaths[section], let next = forward.popLast() else { return }
        forwardPaths[section] = forward
        sectionPaths[section, default: []].append(next)
    }

    /// Selects `section`; selecting the selected one returns it to its root.
    func select(section: SidebarSection) {
        if section == self.section {
            popToRoot()
        }
        self.section = section
    }

    /// Returns the selected section to its root page, keeping the pages for
    /// Forward.
    func popToRoot() {
        guard let path = sectionPaths[section], !path.isEmpty else { return }
        sectionPaths[section] = []
        forwardPaths[section, default: []].append(contentsOf: path.reversed())
    }

    private func setPath(_ path: [AppRoute], in section: SidebarSection) {
        let old = sectionPaths[section] ?? []
        guard path != old else { return }
        if path.count < old.count, Array(old.prefix(path.count)) == path {
            forwardPaths[section, default: []].append(contentsOf: old[path.count...].reversed())
        } else {
            forwardPaths[section] = nil
        }
        sectionPaths[section] = path
    }

    // MARK: Search

    /// Searches for the field's text at once.
    func submitSearch() {
        searchSubmissions += 1
    }

    /// Asks the window to put the cursor in its search field.
    func focusSearch() {
        searchFocusRequests += 1
    }

    func presentNowPlaying() {
        sheet = nil
        isAccountPresented = false
        isNowPlayingPresented = true
    }

    func present(_ sheet: GlobalSheet) {
        self.sheet = sheet
    }

    /// Opens the account sheet, or the Settings window, at `page` when given.
    func openSettings(_ page: SettingsPage? = nil) {
        sheet = nil
        if let settingsWindowOpener {
            if let page { settingsPage = page }
            settingsWindowOpener()
            return
        }
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
        for key in Array(sectionPaths.keys) {
            truncate(&sectionPaths[key, default: []])
        }
        for key in Array(forwardPaths.keys) {
            forwardPaths[key]?.removeAll(where: isRemoved)
        }
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
        searchText = ""
        sectionPaths.removeAll()
        forwardPaths.removeAll()
        section = .home
    }
}

// MARK: - Destinations

extension View {
    /// Registers the shared routes on a navigation stack.
    func appDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteView(route: route)
                .appHidesSystemBackButton()
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
        WithPerceptionTracking {
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
}

private struct GlobalPresentationsModifier: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t
    let layer: Router.Layer

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .sheet(item: sheet) { sheet in
                    WithPerceptionTracking {
                        GlobalSheetView(sheet: sheet)
                    }
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
        WithPerceptionTracking {
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
