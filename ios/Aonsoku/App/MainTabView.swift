import AonsokuKit
import SwiftUI

/// The signed-in interface: Home, Library and Search, each with its own
/// navigation stack. The tab bar shrinks while scrolling down, as in Apple
/// Music, and becomes a sidebar on iPad.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t
    @Namespace private var playerNamespace

    var body: some View {
        @Bindable var router = router
        TabView(selection: selection) {
            Tab(t("sidebar.home"), systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .appDestinations()
                }
            }
            Tab(t("sidebar.library"), systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .appDestinations()
                }
            }
            Tab(t("sidebar.miniSearch"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .appDestinations()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer()
        }
        .fullScreenCover(isPresented: $router.isNowPlayingPresented) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: NowPlayingView.transitionID, in: playerNamespace))
        }
        .sheet(isPresented: $router.isAccountPresented) {
            AccountView()
        }
        .onChange(of: player.playbackStarts) {
            if settings.settings.playback.autoOpenNowPlaying, router.topLayer == .root {
                router.presentNowPlaying()
            }
        }
        .environment(\.playerNamespace, playerNamespace)
        .globalPresentations(.root)
    }

    /// Selecting the current tab again pops it to its root.
    private var selection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { router.select($0) }
        )
    }
}
