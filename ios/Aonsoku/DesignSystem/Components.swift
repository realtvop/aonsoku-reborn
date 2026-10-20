import AonsokuKit
import SwiftUI

// MARK: - Layout

enum Layout {
    /// Leading and trailing page margin in scrolling pages.
    static func margin(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 32 : 20
    }

    static let shelfSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 28
}

extension View {
    /// Applies the page margin for the current size class.
    func pageMargins() -> some View {
        modifier(PageMarginsModifier())
    }
}

private struct PageMarginsModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.padding(.horizontal, Layout.margin(sizeClass))
    }
}

/// Shrinks tiles slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Headers

/// A shelf title. With a route it links to the full list, the way Apple
/// Music's "Recently Added ›" does.
struct SectionHeader: View {
    let title: String
    var route: AppRoute?

    var body: some View {
        if let route {
            NavigationLink(value: route) {
                label(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            label(showsChevron: false)
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tiles

/// An album cover with its title and artist, linking to the album.
struct AlbumTile: View {
    enum Caption {
        case artist
        case year
    }

    let album: Album
    var caption: Caption = .artist

    var body: some View {
        NavigationLink(value: AppRoute.album(album)) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(id: album.coverArt)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(album.name)
                            .lineLimit(1)
                        if album.explicitStatus == .explicit {
                            ExplicitBadge()
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(captionText)
                            .lineLimit(1)
                        AlbumCacheBadge(albumId: album.id)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            AlbumMenuItems(album: album)
        }
    }

    private var captionText: String {
        switch caption {
        case .artist: album.artistLine
        case .year: album.year.map(String.init) ?? album.artistLine
        }
    }
}

/// A playlist cover with its name and length, linking to the playlist.
struct PlaylistTile: View {
    let playlist: Playlist

    @Environment(Localizer.self) private var t

    var body: some View {
        NavigationLink(value: AppRoute.playlist(id: playlist.id)) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(id: playlist.coverArt, placeholder: "music.note.list")
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(t("playlist.songCount", count: playlist.songCount))
                            .lineLimit(1)
                        PlaylistCacheBadge(playlistId: playlist.id)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            PlaylistMenuItems(playlist: playlist)
        }
    }
}

/// A round artist portrait with the name under it.
struct ArtistTile: View {
    let artist: Artist

    var body: some View {
        NavigationLink(value: AppRoute.artist(id: artist.id, name: artist.name)) {
            VStack(spacing: 8) {
                ArtworkImage(id: artist.coverArt, isCircular: true, placeholder: "music.mic")
                Text(artist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            ArtistMenuItems(artist: artist)
        }
    }
}

// MARK: - Collections

/// A horizontal row of albums that snaps to tile edges.
struct AlbumShelf: View {
    let albums: [Album]
    var caption: AlbumTile.Caption = .artist

    var body: some View {
        Shelf(items: albums) { album in
            AlbumTile(album: album, caption: caption)
        }
    }
}

/// A horizontal, snapping row of tiles: a little over two on a phone, so
/// the next one peeks in, and five and a half on a wide iPad window.
struct Shelf<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    var compactSpan = 4
    @ViewBuilder let tile: (Item) -> Tile

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let isRegular = sizeClass == .regular
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Layout.shelfSpacing) {
                ForEach(items) { item in
                    tile(item)
                        .containerRelativeFrame(
                            .horizontal,
                            count: isRegular ? 11 : 9,
                            span: isRegular ? 2 : compactSpan,
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

/// A grid of albums that loads the next page as it scrolls.
struct AlbumGrid: View {
    let collection: PagedCollection<Album>
    var caption: AlbumTile.Caption = .artist

    var body: some View {
        TileGrid {
            ForEach(collection.items) { album in
                AlbumTile(album: album, caption: caption)
                    .onAppear { collection.loadMoreIfNeeded(currentItem: album) }
            }
        }
        if collection.phase == .loadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        }
    }
}

/// An adaptive grid with the page margins, for tiles.
struct TileGrid<Content: View>: View {
    var minimumWidth: CGFloat = 150
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 20
        ) {
            content
        }
        .pageMargins()
    }
}

// MARK: - Songs

/// What a song row shows before the title.
enum SongRowLeading: Equatable {
    case artwork
    case number(Int?)
    case none
}

/// What a song row shows under the title.
enum SongRowSubtitle: Equatable {
    case artist
    /// The album and year, for an artist's songs.
    case album
    case none
}

/// A song in a list: cover or number, title and artist, its download
/// state, length and a menu. Swipe right to queue it.
struct SongRow: View {
    let song: Song
    var leading: SongRowLeading = .artwork
    var subtitle: SongRowSubtitle = .artist
    var showsDuration = true
    var context: SongMenuContext = .standard
    let play: () -> Void

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 4) {
            Button(action: play) {
                HStack(spacing: 12) {
                    leadingView
                    titles
                    Spacer(minLength: 4)
                    SongCacheBadge(songId: song.id)
                    if showsDuration {
                        Text(Formatters.clock(TimeInterval(song.duration)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                SongMenuItems(song: song, context: context)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(t("playlist.buttons.options", ["name": song.title]))
        }
        .contextMenu {
            SongMenuItems(song: song, context: context)
        }
        .swipeActions(edge: .leading) {
            EnqueueSwipeActions(songs: [song])
        }
    }

    private var isCurrent: Bool {
        player.currentSong?.id == song.id
    }

    private var subtitleText: String? {
        switch subtitle {
        case .artist:
            return song.artistLine
        case .album:
            let parts = [song.album, song.year.map(String.init) ?? ""].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .none:
            return nil
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .artwork:
            SongArtwork(song: song)
                .frame(width: 48, height: 48)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.4))
                        NowPlayingIndicator(isPlaying: player.isPlaying)
                            .foregroundStyle(.white)
                    }
                }
        case let .number(number):
            Group {
                if isCurrent {
                    NowPlayingIndicator(isPlaying: player.isPlaying)
                        .foregroundStyle(.tint)
                } else {
                    Text(number.map(String.init) ?? "")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 26)
        case .none:
            EmptyView()
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if song.explicitStatus == .explicit {
                    ExplicitBadge()
                }
            }
            if let subtitleText {
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        // The separator starts under the title, as in Apple Music.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// A song's cover, or its album's when the setting asks for it.
struct SongArtwork: View {
    let song: Song
    var size: ArtworkSize = .small
    var cornerRadius: CGFloat = 6

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ArtworkImage(
            id: song.coverArtId(preferAlbum: settings.settings.playback.useAlbumCoverForSongs),
            size: size,
            cornerRadius: cornerRadius
        )
    }
}

extension Song {
    /// The cover to show: the album's when `preferAlbum` is set and the song
    /// has an album, like the web `getSongCoverArtId`.
    func coverArtId(preferAlbum: Bool) -> String? {
        if preferAlbum, let albumId, !albumId.isEmpty {
            return albumId
        }
        return coverArt
    }
}

/// Animated bars for the song that is playing; still while paused.
struct NowPlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.subheadline.weight(.semibold))
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isPlaying)
            .accessibilityHidden(true)
    }
}

/// The "E" mark on explicit songs and albums.
struct ExplicitBadge: View {
    @Environment(Localizer.self) private var t

    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(t("native.explicit"))
    }
}

/// Play Next and Play Last, for a row's leading swipe.
struct EnqueueSwipeActions: View {
    let songs: [Song]

    @Environment(PlayerStore.self) private var player
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        Button {
            player.enqueue(songs, position: .next, announcingWith: toasts)
        } label: {
            Label(t("options.playNext"), systemImage: QueueSymbol.playNext)
        }
        .tint(.indigo)
        Button {
            player.enqueue(songs, position: .last, announcingWith: toasts)
        } label: {
            Label(t("options.addLast"), systemImage: QueueSymbol.playLast)
        }
        .tint(.orange)
    }
}

enum QueueSymbol {
    static let playNext = "text.line.first.and.arrowtriangle.forward"
    static let playLast = "text.line.last.and.arrowtriangle.forward"
}

extension PlayerStore {
    /// Queues `songs` and confirms it with a short toast.
    func enqueue(
        _ songs: [Song],
        position: QueueInsertPosition,
        announcingWith toasts: ToastCenter
    ) {
        guard !songs.isEmpty else { return }
        enqueue(songs, position: position)
        switch position {
        case .next:
            toasts.show(.key("options.playNext"), style: .success, systemImage: QueueSymbol.playNext)
        case .last:
            toasts.show(.key("options.addLast"), style: .success, systemImage: QueueSymbol.playLast)
        }
    }
}

// MARK: - Download state

/// A song's offline state: downloaded, saved by a smart rule, downloading,
/// or kept after the server removed it. Songs only in the playback cache
/// show nothing.
struct SongCacheBadge: View {
    let songId: String

    @Environment(DownloadsStore.self) private var downloads
    @Environment(Localizer.self) private var t

    var body: some View {
        let _ = downloads.revision
        Group {
            switch downloads.state(ofSong: songId) {
            case .notCached:
                EmptyView()
            case let .downloading(progress):
                ProgressRing(progress: progress)
                    .accessibilityLabel(t("offline.badge.downloading"))
            case let .cached(source, removedFromServer):
                if removedFromServer {
                    Image(systemName: "exclamationmark.icloud")
                        .accessibilityLabel(t("offline.badge.orphan"))
                } else if source == .explicit {
                    Image(systemName: "arrow.down.circle.fill")
                        .accessibilityLabel(t("offline.badge.downloaded"))
                } else if source == .smart {
                    Image(systemName: "arrow.down.circle.dotted")
                        .accessibilityLabel(t("offline.badge.smart"))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct AlbumCacheBadge: View {
    let albumId: String

    @Environment(DownloadsStore.self) private var downloads

    var body: some View {
        let _ = downloads.revision
        CollectionCacheIndicator(state: downloads.state(ofAlbum: albumId))
    }
}

struct PlaylistCacheBadge: View {
    let playlistId: String

    @Environment(DownloadsStore.self) private var downloads

    var body: some View {
        let _ = downloads.revision
        CollectionCacheIndicator(state: downloads.state(ofPlaylist: playlistId))
    }
}

private struct CollectionCacheIndicator: View {
    let state: CollectionCacheState

    @Environment(Localizer.self) private var t

    var body: some View {
        Group {
            switch state {
            case .notCached:
                EmptyView()
            case let .downloading(completed, total):
                ProgressRing(progress: total > 0 ? Double(completed) / Double(total) : nil)
                    .accessibilityLabel(t("offline.badge.downloading"))
            case .cached:
                Image(systemName: "arrow.down.circle.fill")
                    .accessibilityLabel(t("offline.badge.downloaded"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A small circular progress indicator; spins when the progress is unknown.
struct ProgressRing: View {
    let progress: Double?
    var diameter: CGFloat = 13

    var body: some View {
        if let progress {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(min(progress, 1), 0.03))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
            .frame(width: diameter, height: diameter)
        } else {
            ProgressView()
                .controlSize(.mini)
                .frame(width: diameter, height: diameter)
        }
    }
}

// MARK: - Page states

/// A page's first load.
struct LoadingStateView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 80)
    }
}

/// A failed load, with a retry button. Offline, it says so instead of
/// showing the network error.
struct ErrorStateView: View {
    let message: String?
    let retry: () -> Void

    @Environment(NetworkMonitor.self) private var network
    @Environment(Localizer.self) private var t

    var body: some View {
        ContentUnavailableView {
            if network.isOnline {
                Label(t("native.error.title"), systemImage: "exclamationmark.triangle")
            } else {
                Label(t("offline.disconnected"), systemImage: "wifi.slash")
            }
        } description: {
            if let message, network.isOnline {
                Text(message)
            }
        } actions: {
            Button(t("native.generic.retry"), action: retry)
                .buttonStyle(.glass)
        }
    }
}

/// Nothing to show, with an optional action.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description {
                Text(description)
            }
        } actions: {
            actions
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, systemImage: String, description: String? = nil) {
        self.init(title: title, systemImage: systemImage, description: description) {
            EmptyView()
        }
    }
}

extension View {
    /// Shows a paged list's first load, failure or emptiness over it. The
    /// list stays in place underneath, so the title, search field and pull
    /// to refresh keep working.
    func pagedStates<Item: Identifiable & Sendable, Empty: View>(
        _ collection: PagedCollection<Item>,
        @ViewBuilder empty: () -> Empty
    ) -> some View {
        overlay {
            PagedStates(collection: collection, empty: empty())
        }
    }
}

private struct PagedStates<Item: Identifiable & Sendable, Empty: View>: View {
    let collection: PagedCollection<Item>
    let empty: Empty

    var body: some View {
        if collection.isEmpty {
            switch collection.phase {
            case .idle, .loading, .loadingMore:
                LoadingStateView()
            case let .failed(message):
                ErrorStateView(message: message) { collection.retry() }
            case .loaded:
                empty
            }
        }
    }
}

extension View {
    /// `pagedStates` for a list that loads all at once: shows the first
    /// load, a failure or emptiness over the list.
    func loadStates<Empty: View>(
        _ phase: LoadPhase,
        isEmpty: Bool,
        retry: @escaping () -> Void,
        @ViewBuilder empty: () -> Empty
    ) -> some View {
        overlay {
            LoadStates(phase: phase, isEmpty: isEmpty, retry: retry, empty: empty())
        }
    }
}

private struct LoadStates<Empty: View>: View {
    let phase: LoadPhase
    let isEmpty: Bool
    let retry: () -> Void
    let empty: Empty

    var body: some View {
        if isEmpty {
            switch phase {
            case .idle, .loading:
                LoadingStateView()
            case let .failed(message):
                ErrorStateView(message: message, retry: retry)
            case .loaded:
                empty
            }
        }
    }
}

/// A capsule over the content that says the app is offline.
struct OfflineBanner: View {
    @Environment(NetworkMonitor.self) private var network
    @Environment(Localizer.self) private var t

    var body: some View {
        if !network.isOnline {
            Label(t("offline.mode"), systemImage: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// Shows the offline capsule under the navigation bar while offline;
    /// the page scrolls beneath it.
    func offlineBanner() -> some View {
        modifier(OfflineBannerModifier())
    }
}

private struct OfflineBannerModifier: ViewModifier {
    @Environment(NetworkMonitor.self) private var network

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                OfflineBanner()
                    .frame(maxWidth: .infinity)
            }
            .animation(.smooth, value: network.isOnline)
    }
}

// MARK: - Search

extension View {
    /// Adds a search field only when `isEnabled`, for pages that can search
    /// some of what they show and not the rest.
    @ViewBuilder
    func searchable(_ isEnabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if isEnabled {
            searchable(text: text, prompt: Text(prompt))
        } else {
            self
        }
    }
}

// MARK: - Play buttons

/// The Play and Shuffle pair under a header, as in Apple Music.
struct PlayShuffleButtons: View {
    /// False for a single song, which has nothing to shuffle.
    var canShuffle = true
    let play: () -> Void
    let shuffle: () -> Void

    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label(t("options.play"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button(action: shuffle) {
                Label(t("shortcuts.playback.shuffle"), systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canShuffle)
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.glass)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
    }
}
