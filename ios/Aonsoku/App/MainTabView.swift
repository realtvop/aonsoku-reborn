import AonsokuKit
import SwiftUI

/// The signed-in interface: Home, Library and Search, each with its own
/// navigation stack. iPhone uses a continuously animated glass dock; iPad
/// keeps the system tab bar and adaptable sidebar.
struct MainTabView: View {
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var playerNamespace
    @State private var isTabBarMinimized = false
    @State private var primaryTab: AppTab = .home

    private var usesCompactTabBar: Bool { sizeClass == .compact }

    var body: some View {
        @Bindable var router = router
        tabs
            .tabViewStyle(.sidebarAdaptable)
            .toolbar(usesCompactTabBar ? .hidden : .automatic, for: .tabBar)
            .tabBarMinimizeBehavior(usesCompactTabBar ? .never : .onScrollDown)
            .modifier(SystemTabAccessory(isEnabled: !usesCompactTabBar))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if usesCompactTabBar {
                    compactTabBar
                }
            }
            .environment(\.compactTabBarMinimization, minimizationHandler)
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
            .onChange(of: router.selectedTab, initial: true) { _, tab in
                if tab != .search { primaryTab = tab }
                setMinimized(false)
            }
            .onChange(of: typeSize) { _, size in
                if size.isAccessibilitySize { setMinimized(false) }
            }
            .environment(\.playerNamespace, playerNamespace)
            .globalPresentations(.root)
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: selection) {
            Tab(t("sidebar.home"), systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.homePath) {
                    HomeView()
                        .compactTabBarPage()
                        .appDestinations()
                }
            }
            Tab(t("sidebar.library"), systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) {
                    LibraryView()
                        .compactTabBarPage()
                        .appDestinations()
                }
            }
            Tab(t("sidebar.miniSearch"), systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView()
                        .compactTabBarPage()
                        .appDestinations()
                }
            }
        }
    }

    private var compactTabBar: some View {
        CompactTabBar(
            collapse: isTabBarMinimized ? 1 : 0,
            selectedTab: router.selectedTab,
            primaryTab: primaryTab,
            homeTitle: t("sidebar.home"),
            libraryTitle: t("sidebar.library"),
            searchTitle: t("sidebar.miniSearch"),
            select: select
        ) { progress in
            MiniPlayer(compactProgress: progress)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .hideCompactTabBarWithKeyboard()
    }

    private var minimizationHandler: ((Bool) -> Void)? {
        usesCompactTabBar ? { setMinimized($0) } : nil
    }

    private func setMinimized(_ minimized: Bool) {
        let minimized = minimized && !typeSize.isAccessibilitySize
        guard minimized != isTabBarMinimized else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
            isTabBarMinimized = minimized
        }
    }

    private func select(_ tab: AppTab) {
        let wasMinimized = isTabBarMinimized
        setMinimized(false)
        // The minimized leading tab first expands the choices.
        if wasMinimized, tab == router.selectedTab { return }
        router.select(tab)
    }

    /// Selecting the current tab again pops it to its root.
    private var selection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { router.select($0) }
        )
    }
}

private struct SystemTabAccessory: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.tabViewBottomAccessory { MiniPlayer() }
        } else {
            content
        }
    }
}
