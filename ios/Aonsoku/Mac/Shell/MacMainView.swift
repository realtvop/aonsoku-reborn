import AonsokuKit
import Perception
import SwiftUI

/// The signed-in Mac window: the sidebar of sections, each section's own
/// navigation stack with Back and Forward in the toolbar, one search field
/// for the whole library, the player bar along the bottom and Now Playing
/// as an inspector beside the content.
struct MacMainView: View {
    @Environment(Router.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(PinnedHomeStore.self) private var pinned
    @Environment(SettingsStore.self) private var settings
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t
    @Environment(\.openSettings) private var openSettings

    @AppStorage("mac.sidebar.section") private var storedSection = SidebarSection.home.storageKey
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        WithPerceptionTracking {
            // The player sits below the columns rather than over them, so no
            // column (the tinted inspector least of all) shows through it.
            VStack(spacing: 0) {
                splitView
                    .modifier(MacToolbarSearch(showSearch: showSearch))
                    .toolbar {
                        ToolbarItemGroup(placement: .navigation) {
                            WithPerceptionTracking {
                                MacHistoryButtons()
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            WithPerceptionTracking {
                                MacAccountMenu()
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            WithPerceptionTracking {
                                MacInspectorToggle()
                            }
                        }
                    }
                MacPlayerBar()
            }
            .environment(\.horizontalSizeClass, .regular)
            .globalPresentations(.root)
            .modifier(MacShellObservers(storedSection: $storedSection, showSearch: showSearch))
            .onAppear {
                router.settingsWindowOpener = { openSettings() }
                if let section = SidebarSection(storageKey: storedSection) {
                    router.section = section
                }
            }
            .task { await playlists.loadIfNeeded() }
            .task(id: pinned.items) { await pinned.refresh() }
        }
    }

    private var splitView: some View {
        WithPerceptionTracking {
            @AppBindable var router = router
            NavigationSplitView(columnVisibility: $columnVisibility) {
                MacSidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                WithPerceptionTracking {
                    MacSectionStack(section: router.section)
                        .id(router.section)
                        .inspector(isPresented: $router.isNowPlayingPresented) {
                            MacNowPlayingInspector()
                                .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
                        }
                }
            }
        }
    }

    /// Typing in the toolbar field shows its results, from any section.
    private func showSearch() {
        if router.section != .search {
            router.section = .search
        } else if router.canGoBack {
            router.popToRoot()
        }
    }
}

/// The window's search field, which searches from any section.
private struct MacToolbarSearch: ViewModifier {
    let showSearch: () -> Void

    @FocusState private var isFocused: Bool

    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            @AppBindable var router = router
            content
                .searchable(
                    text: $router.searchText,
                    placement: .toolbar,
                    prompt: Text(t("command.inputPlaceholder"))
                )
                .searchFocused($isFocused)
                .onSubmit(of: .search) {
                    showSearch()
                    router.submitSearch()
                }
                .appOnChange(of: router.searchFocusRequests) {
                    isFocused = true
                }
        }
    }
}

/// What the window follows: the search text, the selection to restore,
/// a playlist deleted under its own section and playback that starts.
private struct MacShellObservers: ViewModifier {
    @Binding var storedSection: String
    let showSearch: () -> Void

    @Environment(Router.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SettingsStore.self) private var settings
    @Environment(PlayerStore.self) private var player

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .appOnChange(of: router.searchText) { _, text in
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { showSearch() }
                }
                .appOnChange(of: router.section) { _, section in
                    storedSection = section.storageKey
                }
                .appOnChange(of: playlists.playlists.map(\.id)) { _, ids in
                    // A playlist deleted from its own page leaves its section.
                    if case let .playlist(id) = router.section, playlists.phase == .loaded, !ids.contains(id) {
                        router.section = .playlists
                    }
                }
                .appOnChange(of: player.playbackStarts) {
                    if settings.settings.playback.autoOpenNowPlaying, !router.isNowPlayingPresented {
                        router.presentNowPlaying()
                    }
                }
                .appOnChange(of: player.hasMedia) { _, hasMedia in
                    // As on iOS, Now Playing closes once nothing is loaded.
                    if !hasMedia { router.isNowPlayingPresented = false }
                }
        }
    }
}

/// One section's navigation stack, over the router's path for it.
private struct MacSectionStack: View {
    let section: SidebarSection

    @Environment(Router.self) private var router

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: router.sectionPath) {
                MacSectionRoot(section: section)
                    .appDestinations()
            }
        }
    }
}

/// The page a section opens on.
private struct MacSectionRoot: View {
    let section: SidebarSection

    @Environment(AppModel.self) private var app

    var body: some View {
        WithPerceptionTracking {
            switch section {
            case .home: HomeView()
            case .search: SearchView()
            case .albums: AlbumsListView(filter: AlbumListPreference.load(app.services.preferences))
            case .artists: ArtistsListView()
            case .songs: SongsListView(query: SongListQuery())
            case .playlists: PlaylistsListView()
            case .favorites: FavoritesView()
            case .genres: GenresView()
            case .radios: RadiosView()
            case .downloads: DownloadsView()
            case let .playlist(id): PlaylistDetailView(playlistId: id)
            case let .pinned(item):
                switch item.kind {
                case .album: AlbumDetailView(albumId: item.itemId, preview: nil)
                case .playlist: PlaylistDetailView(playlistId: item.itemId)
                }
            }
        }
    }
}

/// Shows and hides Now Playing beside the content.
private struct MacInspectorToggle: View {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let label = t(router.isNowPlayingPresented ? "native.mac.player.hideNowPlaying" : "native.mac.player.showNowPlaying")
            Button {
                router.isNowPlayingPresented.toggle()
            } label: {
                Label(label, systemImage: "sidebar.right")
            }
            .disabled(!player.hasMedia && !router.isNowPlayingPresented)
            .help(label)
        }
    }
}

/// Back and Forward through the selected section's pages.
private struct MacHistoryButtons: View {
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            ControlGroup {
                Button {
                    router.goBack()
                } label: {
                    Label(t("navigation.back"), systemImage: "chevron.backward")
                }
                .disabled(!router.canGoBack)
                .help(t("navigation.back"))
                Button {
                    router.goForward()
                } label: {
                    Label(t("native.mac.navigation.forward"), systemImage: "chevron.forward")
                }
                .disabled(!router.canGoForward)
                .help(t("native.mac.navigation.forward"))
            }
            .controlGroupStyle(.navigation)
        }
    }
}
