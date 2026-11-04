import AonsokuKit
import Perception
import SwiftUI

/// A throwaway signed-in shell: a sidebar over Home, Library and Search with
/// no player. The Mac shell and player replace it; it exists so the shared
/// screens can run on macOS in the meantime. The avatar's account sheet, which
/// holds Settings, is presented as on iOS so those pages can be reached.
struct MacMainView: View {
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            @AppBindable var router = router
            NavigationSplitView {
                List(selection: sidebarSelection) {
                    Label(t("sidebar.home"), systemImage: "house.fill").tag(AppTab.home)
                    Label(t("sidebar.library"), systemImage: "books.vertical.fill").tag(AppTab.library)
                    Label(t("sidebar.miniSearch"), systemImage: "magnifyingglass").tag(AppTab.search)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
            } detail: {
                WithPerceptionTracking {
                    switch router.selectedTab {
                    case .home: home
                    case .library: library
                    case .search: search
                    }
                }
            }
            .sheet(isPresented: $router.isAccountPresented) {
                WithPerceptionTracking { AccountView() }
                    .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
            }
            .globalPresentations(.root)
        }
    }

    private var home: some View {
        WithPerceptionTracking {
            @AppBindable var router = router
            NavigationStack(path: $router.homePath) {
                HomeView().appDestinations()
            }
        }
    }

    private var library: some View {
        WithPerceptionTracking {
            @AppBindable var router = router
            NavigationStack(path: $router.libraryPath) {
                LibraryView().appDestinations()
            }
        }
    }

    private var search: some View {
        WithPerceptionTracking {
            @AppBindable var router = router
            NavigationStack(path: $router.searchPath) {
                SearchView().appDestinations()
            }
        }
    }

    private var sidebarSelection: Binding<AppTab?> {
        Binding(get: { router.selectedTab }, set: { if let tab = $0 { router.select(tab) } })
    }
}
