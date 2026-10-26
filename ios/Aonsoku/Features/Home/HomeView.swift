import AonsokuKit
import Perception
import SwiftUI

/// Home, laid out like the web's: what other devices are playing, the
/// featured album carousel, the albums and playlists the user pinned, then
/// shelves for what they played recently and most, what was added and a
/// random pick.
struct HomeView: View {
    @Environment(HomeStore.self) private var home
    @Environment(PinnedHomeStore.self) private var pinned
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    OtherDevicesSection()
                    Group {
                        if !home.hasCarousel, isLoading {
                            HomeSkeleton(showCarousel: true, shelfCount: 0)
                        } else if !home.carousel.isEmpty {
                            FeaturedCarousel(albums: home.carousel)
                        }
                        if !pinned.resolved.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: t("home.pinned"))
                                    .pageMargins()
                                HomeShelf(items: pinned.resolved) { content in
                                    WithPerceptionTracking {
                                        switch content {
                                        case let .album(album):
                                            AlbumTile(album: album)
                                        case let .playlist(playlist):
                                            PlaylistTile(playlist: playlist)
                                        }
                                    }
                                }
                            }
                        }
                        ForEach(HomeSection.allCases) { section in
                            WithPerceptionTracking {
                                let albums = home.albums(in: section)
                                if home.sections[section] == nil, isLoading {
                                    HomeSkeleton(showCarousel: false, shelfCount: 1)
                                } else if !albums.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        SectionHeader(title: t(section.titleKey), route: .albums(section.listFilter))
                                            .pageMargins()
                                        HomeShelf(items: albums) { album in
                                            WithPerceptionTracking {
                                                AlbumTile(album: album)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .overlay { states }
            .offlineBanner()
            .themedBackground()
            .rootPageHeader(t("sidebar.home"))
            .refreshable {
                async let albums: Void = home.refresh()
                async let pins: Void = pinned.refresh()
                _ = await (albums, pins)
                if network.isOnline, !sync.isSyncing {
                    sync.syncIncremental()
                }
            }
            .task { await home.loadIfNeeded() }
            .task(id: pinned.items) { await pinned.refresh() }
            .task(id: network.isOnline) {
                // Keeps Recently Played current while Home is on screen, as the
                // web does every two minutes.
                guard network.isOnline else { return }
                async let albums: Void = home.refreshAutomatically()
                async let pins: Void = pinned.refresh()
                _ = await (albums, pins)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { return }
                    await home.refreshRecentlyPlayed()
                }
            }
        }
    }

    private var isLoading: Bool {
        home.phase == .idle || home.phase == .loading
    }

    @ViewBuilder
    private var states: some View {
        if home.isEmpty, pinned.resolved.isEmpty {
            switch home.phase {
            case .idle, .loading:
                EmptyView()
            case let .failed(message):
                ErrorStateView(message: message) {
                    Task { await home.refresh() }
                }
            case .loaded:
                EmptyStateView(
                    title: t("native.home.empty.title"),
                    systemImage: "music.note.house",
                    description: t("native.home.empty.description")
                )
            }
        }
    }
}

/// Mirrors the featured card and album shelves while the first Home load runs.
private struct HomeSkeleton: View {
    var showCarousel = true
    var shelfCount = 3
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var tileWidth: CGFloat { sizeClass == .regular ? 180 : 160 }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if showCarousel {
                    HStack(spacing: sizeClass == .regular ? 22 : 14) {
                        block()
                            .aspectRatio(1, contentMode: .fit)
                        VStack(alignment: .leading, spacing: 8) {
                            Spacer(minLength: 0)
                            block().frame(height: 20)
                            block().frame(width: 100, height: 14)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(sizeClass == .regular ? 22 : 14)
                    .frame(height: sizeClass == .regular ? 250 : 150)
                    .themeBackground(.card, in: .rect(cornerRadius: 14))
                    .pageMargins()

                }
                ForEach(0..<shelfCount, id: \.self) { _ in
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 12) {
                            block().frame(width: 160, height: 24)
                                .pageMargins()
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: Layout.shelfSpacing) {
                                    ForEach(0..<4, id: \.self) { _ in
                                        WithPerceptionTracking {
                                            VStack(alignment: .leading, spacing: 8) {
                                                block().frame(height: tileWidth)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    block().frame(height: 16)
                                                    block().frame(width: tileWidth * 0.65, height: 12)
                                                }
                                            }
                                            .frame(width: tileWidth)
                                        }
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .appHorizontalScrollMargins(Layout.margin(sizeClass))
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func block() -> some View {
        RoundedRectangle(cornerRadius: Layout.artworkRadius, style: .continuous)
            .themeFill(.muted)
    }
}

/// Larger covers for touch browsing, with native free scrolling between tiles.
private struct HomeShelf<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        WithPerceptionTracking {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Layout.shelfSpacing) {
                    ForEach(items) { item in
                        WithPerceptionTracking {
                            tile(item)
                                .frame(width: sizeClass == .regular ? 180 : 160)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .appScrollClipDisabled()
            .appHorizontalScrollMargins(Layout.margin(sizeClass))
        }
    }
}

// MARK: - Other devices

/// Playback on the user's other devices, like the web Home overview: a
/// small caption and a card per device. A tap opens the devices sheet to
/// control it or continue it here.
private struct OtherDevicesSection: View {
    @Environment(CoordinationStore.self) private var coordination
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        WithPerceptionTracking {
            let devices = coordination.groups.live + coordination.groups.offlineSnapshots
            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        router.present(.devices)
                    } label: {
                        TitleDisclosureLabel {
                            Label {
                                Text(t("settings.crossDevice.playback.otherDevices"))
                                    .textCase(.uppercase)
                                    .tracking(0.6)
                                    .themeForeground(.mutedForeground)
                            } icon: {
                                Image(systemName: "hifispeaker.2.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    }
                    .buttonStyle(.touchFeedback)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint(t("settings.crossDevice.playback.showDevices"))
                    VStack(spacing: 8) {
                        ForEach(devices) { summary in
                            WithPerceptionTracking {
                                Button {
                                    router.present(.devices)
                                } label: {
                                    HStack(spacing: 8) {
                                        DevicePlaybackRow(summary: summary)
                                        Image(systemName: "chevron.forward")
                                            .font(.footnote.weight(.semibold))
                                            .themeForeground(.mutedForeground, opacity: 0.6)
                                    }
                                    .padding(12)
                                    .cardSurface(cornerRadius: 14)
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }
                }
                .pageMargins()
            }
        }
    }
}

// MARK: - Featured

/// Featured albums one at a time, like the web's Home header. It advances
/// every ten seconds and wraps around, unless the user is scrolling it or
/// prefers less motion.
private struct FeaturedCarousel: View {
    let albums: [Album]

    @State private var selection: Int? = 1
    @State private var isScrolling = false

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WithPerceptionTracking {
            let margin = Layout.margin(sizeClass)
            Group {
                if #available(iOS 17, *) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: margin) {
                            // The end copies let both swipes and autoplay cross the seam.
                            ForEach(0..<pageCount, id: \.self) { page in
                                WithPerceptionTracking {
                                    FeaturedCard(album: albums[albumIndex(for: page)])
                                        .appContainerRelativeFrame(.horizontal)
                                }
                            }
                        }
                        .appScrollTargetLayout()
                    }
                    .appViewAlignedScrolling()
                    .scrollPosition(id: $selection)
                    .scrollIndicators(.hidden)
                    .appScrollClipDisabled()
                    .appHorizontalScrollMargins(margin)
                    .appOnScrollPhaseChange { _, phase in
                        isScrolling = phase != .idle
                        if phase == .idle {
                            recenterSelection()
                        }
                    }
                } else {
                    TabView(selection: $selection) {
                        ForEach(0..<pageCount, id: \.self) { page in
                            WithPerceptionTracking {
                                FeaturedCard(album: albums[albumIndex(for: page)])
                                    .padding(.horizontal, margin)
                                    .tag(Optional(page))
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: sizeClass == .regular ? 250 : 150)
                    .appOnScrollPhaseChange { _, phase in
                        isScrolling = phase != .idle
                        if phase == .idle { recenterSelection() }
                    }
                    .task(id: selection) {
                        // A programmatic page change has no drag/deceleration callback.
                        try? await Task.sleep(for: .milliseconds(650))
                        guard !Task.isCancelled, !isScrolling else { return }
                        recenterSelection()
                    }
                }
            }
            .appOnChange(of: albums.map(\.id), initial: true) { _, _ in
                setSelectionWithoutAnimation(albums.count > 1 ? 1 : 0)
            }
            .task(id: canAutoAdvance ? albums.map(\.id) : []) {
                guard canAutoAdvance else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, canAutoAdvance else { return }
                    withAnimation(.smooth(duration: 0.6)) {
                        selection = min((selection ?? 1) + 1, albums.count + 1)
                    }
                }
            }
        }
    }

    private var pageCount: Int {
        albums.count > 1 ? albums.count + 2 : albums.count
    }

    private var canAutoAdvance: Bool {
        albums.count > 1 && scenePhase == .active && !reduceMotion && !voiceOver && !isScrolling
    }

    private func albumIndex(for page: Int) -> Int {
        albums.count > 1 ? (page + albums.count - 1) % albums.count : page
    }

    private func recenterSelection() {
        guard albums.count > 1 else { return }
        if selection == 0 {
            setSelectionWithoutAnimation(albums.count)
        } else if selection == albums.count + 1 {
            setSelectionWithoutAnimation(1)
        }
    }

    private func setSelectionWithoutAnimation(_ page: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = page
        }
    }
}

/// An album as the web's header card: the cover beside its title, artist
/// and details, over its own art blurred behind a wash of the theme's
/// background, with a glass play button.
private struct FeaturedCard: View {
    let album: Album

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t
    @Environment(\.themeContext) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        WithPerceptionTracking {
            let height: CGFloat = sizeClass == .regular ? 250 : 150
            let padding: CGFloat = sizeClass == .regular ? 22 : 14
            NavigationLink(value: AppRoute.album(album)) {
                HStack(spacing: padding) {
                    ArtworkImage(id: album.coverArt, cornerRadius: 8)
                        .frame(width: height - padding * 2, height: height - padding * 2)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Spacer(minLength: 0)
                        Text(album.name)
                            .displayFont(.card)
                            .lineLimit(2)
                        Text(album.artistLine)
                            .font(.subheadline.weight(.semibold))
                            .opacity(0.7)
                            .lineLimit(1)
                        if let details {
                            Text(details)
                                .font(.caption.weight(.medium))
                                .opacity(0.6)
                                .lineLimit(1)
                                .padding(.top, 2)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .multilineTextAlignment(.leading)
                    .padding(.trailing, 44)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(padding)
                .frame(height: height)
                .background { backdrop }
                .clipShape(Self.shape)
                .overlay {
                    WithPerceptionTracking {
                        Self.shape.strokeBorder(theme.palette.border, lineWidth: 1)
                    }
                }
                .contentShape(Self.shape)
            }
            .buttonStyle(.pressable)
            .contextMenu {
                AlbumMenuItems(album: album)
            }
            .overlay(alignment: .bottomTrailing) {
                WithPerceptionTracking {
                    Button {
                        Task { await player.playAlbum(id: album.id) }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.body)
                            .frame(width: 24, height: 24)
                    }
                    .appGlassButtonStyle()
                    .appCircularButtonBorder()
                    .padding(padding - 4)
                    .accessibilityLabel(t("options.play"))
                }
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            theme.palette.background
            ArtworkBackdrop(id: album.coverArt, size: .medium)
                .scaleEffect(1.4)
                .blur(radius: 24)
            LinearGradient(
                colors: [theme.palette.background.opacity(0.4), theme.palette.background.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }

    /// "Genre · Year · 45 min".
    private var details: String? {
        let parts = [
            album.genre,
            album.year.flatMap { $0 > 0 ? String($0) : nil },
            album.duration > 0 ? Formatters.totalDuration(album.duration, locale: locale) : nil,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
