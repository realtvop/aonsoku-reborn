import AonsokuKit
import SwiftUI

/// Home, after Apple Music's Home: what other devices are playing, a
/// carousel of featured albums, the albums and playlists the user pinned,
/// then shelves for what they played recently and most, what was added and
/// a random pick.
struct HomeView: View {
    @Environment(HomeStore.self) private var home
    @Environment(PinnedHomeStore.self) private var pinned
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Localizer.self) private var t

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                OtherDevicesShelf()
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

/// Playback on the user's other devices, like the web Home overview. A tap
/// opens the devices sheet to control it or continue it here.
private struct OtherDevicesShelf: View {
    @Environment(CoordinationStore.self) private var coordination
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let devices = coordination.groups.live + coordination.groups.offlineSnapshots
        if !devices.isEmpty {
            let isRegular = sizeClass == .regular
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(t("settings.crossDevice.playback.otherDevices"))
                        .font(.title2.bold())
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button(t("settings.crossDevice.playback.showDevices")) {
                        router.present(.devices)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .pageMargins()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Layout.shelfSpacing) {
                        ForEach(devices) { summary in
                            Button {
                                router.present(.devices)
                            } label: {
                                DevicePlaybackRow(summary: summary)
                                    .padding(12)
                                    .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.pressable)
                            .containerRelativeFrame(
                                .horizontal,
                                count: isRegular ? 3 : 10,
                                span: isRegular ? 1 : 8,
                                spacing: Layout.shelfSpacing
                            )
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .contentMargins(.horizontal, Layout.margin(sizeClass), for: .scrollContent)
            }
        }
    }
}

// MARK: - Featured

/// Large cards that snap one at a time; the next one peeks in on a phone.
private struct FeaturedCarousel: View {
    let albums: [Album]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let isRegular = sizeClass == .regular
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Layout.shelfSpacing) {
                ForEach(albums) { album in
                    FeaturedCard(album: album)
                        .containerRelativeFrame(
                            .horizontal,
                            count: isRegular ? 7 : 10,
                            span: isRegular ? 3 : 9,
                            spacing: Layout.shelfSpacing
                        )
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .contentMargins(.horizontal, Layout.margin(sizeClass), for: .scrollContent)
    }
}

/// An album as an editorial card: the cover melting into a footer in the
/// cover's own color, with a glass play button.
private struct FeaturedCard: View {
    let album: Album

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t
    @State private var palette: ArtworkPalette?

    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        NavigationLink(value: AppRoute.album(album)) {
            VStack(alignment: .leading, spacing: 0) {
                ArtworkImage(id: album.coverArt, size: .large, cornerRadius: 0)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [tint.opacity(0), tint], startPoint: .top, endPoint: .bottom)
                            .frame(height: 72)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.headline)
                    Text(album.artistLine)
                        .font(.subheadline)
                        .opacity(0.85)
                    Text(details)
                        .font(.caption)
                        .opacity(0.7)
                }
                .lineLimit(1)
                .foregroundStyle(textColor)
                .padding(.leading, 16)
                .padding(.trailing, 64)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint)
            }
            .clipShape(Self.shape)
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
                    .font(.title3)
                    .foregroundStyle(textColor)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(tint.opacity(0.3)).interactive(), in: .circle)
            .padding(14)
            .accessibilityLabel(t("options.play"))
        }
        .artworkPalette(album.coverArt, into: $palette)
    }

    private var tint: Color {
        palette?.dominant ?? Color(white: 0.18)
    }

    private var textColor: Color {
        palette?.foreground ?? .white
    }

    /// "Genre · Year"; a space keeps every card the same height.
    private var details: String {
        let parts = [album.genre, album.year.map(String.init)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}
