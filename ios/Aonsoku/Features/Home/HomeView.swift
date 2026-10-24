import AonsokuKit
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                OtherDevicesSection()
                if !home.carousel.isEmpty {
                    FeaturedCarousel(albums: home.carousel)
                }
                if !pinned.resolved.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: t("home.pinned"))
                            .pageMargins()
                        Shelf(items: pinned.resolved) { content in
                            switch content {
                            case let .album(album):
                                AlbumTile(album: album)
                            case let .playlist(playlist):
                                PlaylistTile(playlist: playlist)
                            }
                        }
                    }
                }
                ForEach(HomeSection.allCases) { section in
                    let albums = home.albums(in: section)
                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: t(section.titleKey), route: .albums(section.listFilter))
                                .pageMargins()
                            AlbumShelf(albums: albums)
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
        .navigationTitle(t("sidebar.home"))
        .accountToolbar()
        .refreshable {
            await home.refresh()
            await pinned.resolve()
            if network.isOnline, !sync.isSyncing {
                sync.syncIncremental()
            }
        }
        .task { await home.loadIfNeeded() }
        .task(id: pinned.items) { await pinned.resolve() }
        .task(id: network.isOnline) {
            // Keeps Recently Played current while Home is on screen, as the
            // web does every two minutes.
            guard network.isOnline else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await home.refreshRecentlyPlayed()
            }
        }
    }

    @ViewBuilder
    private var states: some View {
        if home.isEmpty, pinned.resolved.isEmpty {
            switch home.phase {
            case .idle, .loading:
                LoadingStateView()
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

// MARK: - Other devices

/// Playback on the user's other devices, like the web Home overview: a
/// small caption and a card per device. A tap opens the devices sheet to
/// control it or continue it here.
private struct OtherDevicesSection: View {
    @Environment(CoordinationStore.self) private var coordination
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        let devices = coordination.groups.live + coordination.groups.offlineSnapshots
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label {
                        Text(t("settings.crossDevice.playback.otherDevices"))
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .foregroundStyle(ThemeColor.mutedForeground)
                    } icon: {
                        Image(systemName: "hifispeaker.2.fill")
                            .foregroundStyle(.tint)
                    }
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button {
                        router.present(.devices)
                    } label: {
                        HStack(spacing: 3) {
                            Text(t("settings.crossDevice.playback.showDevices"))
                            Image(systemName: "arrow.right")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
                VStack(spacing: 8) {
                    ForEach(devices) { summary in
                        Button {
                            router.present(.devices)
                        } label: {
                            HStack(spacing: 8) {
                                DevicePlaybackRow(summary: summary)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(ThemeColor.mutedForeground.opacity(0.6))
                            }
                            .padding(12)
                            .cardSurface(cornerRadius: 14)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .pageMargins()
        }
    }
}

// MARK: - Featured

/// Featured albums one at a time, like the web's Home header. It advances
/// every ten seconds and wraps around, unless the user is scrolling it or
/// prefers less motion.
private struct FeaturedCarousel: View {
    let albums: [Album]

    @State private var selection: String?
    @State private var isInteracting = false

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        let margin = Layout.margin(sizeClass)
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: margin) {
                    ForEach(albums) { album in
                        FeaturedCard(album: album)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selection)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .onScrollPhaseChange { _, phase in
                isInteracting = phase == .interacting || phase == .decelerating
            }
            if albums.count > 1 {
                PageDots(count: albums.count, selected: selectedIndex)
            }
        }
        .task(id: selection) {
            guard albums.count > 1, !reduceMotion, !voiceOver else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, !isInteracting else { return }
            let next = albums[(selectedIndex + 1) % albums.count].id
            withAnimation(.smooth(duration: 0.6)) {
                selection = next
            }
        }
    }

    private var selectedIndex: Int {
        selection.flatMap { id in albums.firstIndex { $0.id == id } } ?? 0
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
                Self.shape.strokeBorder(theme.palette.border, lineWidth: 1)
            }
            .contentShape(Self.shape)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            AlbumMenuItems(album: album)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                Task { await player.playAlbum(id: album.id) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.body)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(padding - 4)
            .accessibilityLabel(t("options.play"))
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

/// Which featured card is showing: a wider capsule in the accent color.
private struct PageDots: View {
    let count: Int
    let selected: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selected ? AnyShapeStyle(.tint) : AnyShapeStyle(ThemeColor.border))
                    .frame(width: index == selected ? 16 : 6, height: 6)
            }
        }
        .animation(.smooth, value: selected)
        .accessibilityHidden(true)
    }
}
