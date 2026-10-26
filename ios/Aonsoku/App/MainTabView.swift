import AonsokuKit
import Perception
import SwiftUI

/// The signed-in interface: Home, Library and Search, each with its own
/// navigation stack. The tab bar shrinks while scrolling down, as in Apple
/// Music, and becomes a sidebar on iPad.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            @Perception.Bindable var router = router
            TabView(selection: selection) {
                Tab(t("sidebar.home"), systemImage: "house.fill", value: AppTab.home) {
                    NavigationStack(path: $router.homePath) {
                        WithPerceptionTracking {
                            HomeView()
                                .appDestinations()
                        }
                    }
                }
                Tab(t("sidebar.library"), systemImage: "books.vertical.fill", value: AppTab.library) {
                    NavigationStack(path: $router.libraryPath) {
                        WithPerceptionTracking {
                            LibraryView()
                                .appDestinations()
                        }
                    }
                }
                Tab(t("sidebar.miniSearch"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                    NavigationStack(path: $router.searchPath) {
                        WithPerceptionTracking {
                            SearchView()
                                .appDestinations()
                        }
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                PlayerAccessorySlot()
            }
            .nowPlayingPresentation()
            .sheet(isPresented: $router.isAccountPresented) {
                WithPerceptionTracking {
                    AccountView()
                }
            }
            .appOnChange(of: player.playbackStarts) {
                if settings.settings.playback.autoOpenNowPlaying, router.topLayer == .root {
                    router.presentNowPlaying()
                }
            }
            .globalPresentations(.root)
        }
    }

    /// Selecting the current tab again pops it to its root.
    private var selection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { router.select($0) }
        )
    }
}
