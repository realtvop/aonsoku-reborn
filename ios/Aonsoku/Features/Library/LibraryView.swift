import AonsokuKit
import Perception
import SwiftUI

/// The Library tab, like the web's mobile library: the kinds of things in
/// the library as rows with icon tiles, then the playlists.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SettingsStore.self) private var settings
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Playlists shown here; the full list has search and editing.
    private static let playlistLimit = 12

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    VStack(spacing: 2) {
                        ForEach(categories) { category in
                            WithPerceptionTracking {
                                Button {
                                    router.navigate(to: route(for: category))
                                } label: {
                                    LibraryRow(title: t(category.titleKey)) {
                                        IconTile(systemImage: category.symbol)
                                    }
                                }
                                .buttonStyle(RowHighlightStyle())
                            }
                        }
                    }
                    .padding(.horizontal, rowInset)
                    playlistsSection
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .offlineBanner()
            .themedBackground()
            .rootPageHeader(t("sidebar.library"))
            .refreshable {
                await playlists.reload()
                if network.isOnline, !sync.isSyncing {
                    sync.syncIncremental()
                }
            }
            .task { await playlists.loadIfNeeded() }
        }
    }

    /// Rows reach past the margin by their own padding, so their icons line
    /// up with the titles while the highlight has room around them.
    private var rowInset: CGFloat {
        Layout.margin(sizeClass) - libraryRowPadding
    }

    @ViewBuilder
    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionHeader(title: t("sidebar.playlists"), route: .playlists)
                Button {
                    router.present(.createPlaylist(songs: []))
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(t("options.playlist.create"))
            }
            .pageMargins()
            if playlists.playlists.isEmpty {
                if playlists.phase == .loaded {
                    Text(t("sidebar.emptyPlaylist"))
                        .font(.subheadline)
                        .foregroundStyle(ThemeColor.mutedForeground)
                        .pageMargins()
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(playlists.playlists.prefix(Self.playlistLimit)) { playlist in
                        WithPerceptionTracking {
                            NavigationLink(value: AppRoute.playlist(id: playlist.id)) {
                                LibraryRow(
                                    title: playlist.name,
                                    subtitle: t("playlist.songCount", count: playlist.songCount)
                                ) {
                                    ArtworkImage(
                                        id: playlist.coverArt,
                                        size: .small,
                                        cornerRadius: Layout.rowArtworkRadius,
                                        placeholder: "music.note.list"
                                    )
                                    .frame(width: 44, height: 44)
                                }
                            }
                            .buttonStyle(RowHighlightStyle())
                            .contextMenu {
                                PlaylistMenuItems(playlist: playlist)
                            }
                        }
                    }
                }
                .padding(.horizontal, rowInset)
            }
        }
    }

    private var categories: [LibraryCategory] {
        LibraryCategory.allCases.filter { category in
            category != .radios || !settings.settings.content.hideRadiosSection
        }
    }

    /// Albums open with the order the user picked last time, read when the
    /// row is tapped so a change made in the list is never stale.
    private func route(for category: LibraryCategory) -> AppRoute {
        switch category {
        case .artists: .artists
        case .albums: .albums(AlbumListPreference.load(app.services.preferences))
        case .songs: .songs(SongListQuery())
        case .genres: .genres
        case .favorites: .favorites
        case .radios: .radios
        case .downloads: .downloads
        }
    }
}

/// The web's mobile library order, with Genres and Downloaded added.
private enum LibraryCategory: String, CaseIterable, Identifiable {
    case artists
    case songs
    case albums
    case favorites
    case genres
    case radios
    case downloads

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .artists: "sidebar.artists"
        case .songs: "sidebar.songs"
        case .albums: "sidebar.albums"
        case .favorites: "sidebar.favorites"
        case .genres: "table.columns.genres"
        case .radios: "sidebar.radios"
        case .downloads: "offline.badge.downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .artists: "music.mic"
        case .songs: "music.note"
        case .albums: "square.stack"
        case .favorites: "heart"
        case .genres: "guitars"
        case .radios: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// The inset of a library row's content from its highlight.
private let libraryRowPadding: CGFloat = 10

/// A library row: an icon tile or cover, the title and a chevron.
private struct LibraryRow<Leading: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let leading: Leading

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(ThemeColor.mutedForeground)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ThemeColor.mutedForeground.opacity(0.7))
            }
            .padding(.horizontal, libraryRowPadding)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
    }
}

/// Highlights a row on a rounded patch of the theme's accent while it is
/// pressed, like the web's `active:bg-accent`.
struct RowHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WithPerceptionTracking {
            configuration.label
                .background {
                    WithPerceptionTracking {
                        if configuration.isPressed {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(ThemeColor.accent.opacity(0.7))
                        }
                    }
                }
        }
    }
}
