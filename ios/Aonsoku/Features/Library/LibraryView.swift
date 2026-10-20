import AonsokuKit
import SwiftUI

/// The Library tab, after Apple Music's: the kinds of things in the
/// library as rows, then a grid of the albums added most recently.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(HomeStore.self) private var home
    @Environment(SettingsStore.self) private var settings
    @Environment(NetworkMonitor.self) private var network
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(Localizer.self) private var t

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                VStack(spacing: 0) {
                    ForEach(categories) { category in
                        LibraryCategoryRow(category: category) {
                            router.navigate(to: route(for: category))
                        }
                    }
                }
                let recent = home.albums(in: .recentlyAdded)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: t("home.recentlyAdded"), route: .albums(.recentlyAdded))
                            .pageMargins()
                        TileGrid {
                            ForEach(recent) { album in
                                AlbumTile(album: album)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .offlineBanner()
        .themedBackground()
        .navigationTitle(t("sidebar.library"))
        .accountToolbar()
        .refreshable {
            await home.refresh()
            if network.isOnline, !sync.isSyncing {
                sync.syncIncremental()
            }
        }
        .task { await home.loadIfNeeded() }
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
        case .playlists: .playlists
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

private enum LibraryCategory: String, CaseIterable, Identifiable {
    case playlists
    case artists
    case albums
    case songs
    case genres
    case favorites
    case radios
    case downloads

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .playlists: "sidebar.playlists"
        case .artists: "sidebar.artists"
        case .albums: "sidebar.albums"
        case .songs: "sidebar.songs"
        case .genres: "table.columns.genres"
        case .favorites: "sidebar.favorites"
        case .radios: "sidebar.radios"
        case .downloads: "offline.badge.downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .favorites: "heart"
        case .radios: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"
        }
    }
}

/// A category as a tall row with a tinted symbol, separated by hairlines
/// that start at the title.
private struct LibraryCategoryRow: View {
    let category: LibraryCategory
    let action: () -> Void

    @Environment(Localizer.self) private var t

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: category.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                Text(t(category.titleKey))
                    .font(.title3)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .pageMargins()
            .overlay(alignment: .bottom) {
                Divider()
                    .padding(.leading, 44)
                    .pageMargins()
            }
            .contentShape(.rect)
        }
        .buttonStyle(RowHighlightStyle())
    }
}

/// Highlights a full-width row while it is pressed, like a list row.
struct RowHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if configuration.isPressed {
                    Color.primary.opacity(0.08)
                }
            }
    }
}
