import AonsokuKit
import Perception
import SwiftUI

/// Each tab retains its own navigation path on every supported system.
struct MainTabView: View {
    @State private var presentation = PlayerPresentationState()
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        WithPerceptionTracking {
            @Perception.Bindable var router = router
            Group {
                if #available(iOS 26, *) { modernTabs }
                else { legacyNavigation }
            }
            .environment(presentation)
            .nowPlayingPresentation(presentation)
            .sheet(isPresented: $router.isAccountPresented) {
                WithPerceptionTracking { AccountView() }
            }
            .appOnChange(of: player.playbackStarts) {
                if settings.settings.playback.autoOpenNowPlaying, router.topLayer == .root {
                    router.presentNowPlaying()
                }
            }
            .globalPresentations(.root)
        }
    }

    @available(iOS 26, *)
    private var modernTabs: some View {
        WithPerceptionTracking {
            TabView(selection: selection) {
                Tab(t("sidebar.home"), systemImage: "house.fill", value: AppTab.home) { home }
                Tab(t("sidebar.library"), systemImage: "books.vertical.fill", value: AppTab.library) { library }
                Tab(t("sidebar.miniSearch"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) { search }
            }
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory {
                PlayerAccessorySlot().environment(presentation)
            }
        }
    }

    private var legacyNavigation: some View {
        WithPerceptionTracking {
            if sizeClass == .regular {
                NavigationSplitView {
                    WithPerceptionTracking {
                        List(selection: sidebarSelection) {
                            Label(t("sidebar.home"), systemImage: "house.fill").tag(AppTab.home)
                            Label(t("sidebar.library"), systemImage: "books.vertical.fill").tag(AppTab.library)
                            Label(t("sidebar.miniSearch"), systemImage: "magnifyingglass").tag(AppTab.search)
                        }
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .themedBackground()
                        .navigationTitle("Aonsoku")
                    }
                } detail: {
                    WithPerceptionTracking {
                        switch router.selectedTab {
                        case .home: home
                        case .library: library
                        case .search: search
                        }
                    }
                }
            } else {
                TabView(selection: selection) {
                    home.tabItem { Label(t("sidebar.home"), systemImage: "house.fill") }.tag(AppTab.home)
                    library.tabItem { Label(t("sidebar.library"), systemImage: "books.vertical.fill") }.tag(AppTab.library)
                    search.tabItem { Label(t("sidebar.miniSearch"), systemImage: "magnifyingglass") }.tag(AppTab.search)
                }
            }
        }
    }

    private var home: some View {
        WithPerceptionTracking {
            @Perception.Bindable var router = router
            NavigationStack(path: $router.homePath) {
                HomeView().appDestinations()
            }
            .legacyPlayerAccessory(isActive: router.selectedTab == .home)
        }
    }

    private var library: some View {
        WithPerceptionTracking {
            @Perception.Bindable var router = router
            NavigationStack(path: $router.libraryPath) {
                LibraryView().appDestinations()
            }
            .legacyPlayerAccessory(isActive: router.selectedTab == .library)
        }
    }

    private var search: some View {
        WithPerceptionTracking {
            @Perception.Bindable var router = router
            NavigationStack(path: $router.searchPath) {
                SearchView().appDestinations()
            }
            .legacyPlayerAccessory(isActive: router.selectedTab == .search)
        }
    }

    private var selection: Binding<AppTab> {
        Binding(get: { router.selectedTab }, set: { router.select($0) })
    }

    private var sidebarSelection: Binding<AppTab?> {
        Binding(get: { router.selectedTab }, set: { if let tab = $0 { router.select(tab) } })
    }
}

private extension View {
    @ViewBuilder func legacyPlayerAccessory(isActive: Bool) -> some View {
        if #available(iOS 26, *) { self }
        else {
            // Inset the stack, above the native tab bar, rather than the whole TabView.
            safeAreaInset(edge: .bottom, spacing: 0) {
                LegacyPlayerAccessorySlot(isActive: isActive)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }
}

/// Layout only. The same presentation host still owns the sole cover and mini player.
private struct LegacyPlayerAccessorySlot: View {
    let isActive: Bool
    @Environment(PlayerPresentationState.self) private var presentation
    @State private var frame = CGRect.zero

    var body: some View {
        WithPerceptionTracking {
            Color.clear
                .frame(height: 36)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                    frame = rect
                    publish(rect)
                }
                .appOnChange(of: isActive, initial: true) { publish(frame) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func publish(_ frame: CGRect) {
        guard isActive, frame.width > 0, frame.height > 0 else { return }
        presentation.accessory = PlayerAccessoryLayout(frame: frame, compactProgress: 0)
    }
}
