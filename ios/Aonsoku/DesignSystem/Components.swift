import AonsokuKit
import SwiftUI

// MARK: - Layout

enum Layout {
    /// Leading and trailing page margin in scrolling pages: the web's 1rem
    /// on a phone, which also lines up with the large title.
    static func margin(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 32 : 16
    }

    static let shelfSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 28
    /// Covers in tiles and grids, close to the web's small radius.
    static let artworkRadius: CGFloat = 6
    /// Covers in rows.
    static let rowArtworkRadius: CGFloat = 5
}

extension View {
    /// Applies the page margin for the current size class.
    func pageMargins() -> some View {
        modifier(PageMarginsModifier())
    }

    /// List row insets as tight as the web's mobile rows: `vertical` above
    /// and below and the page margins at the sides, less `trailingInset` for
    /// a row whose trailing button brings its own padding. iOS 26's default
    /// row insets make rows half again as tall.
    func compactRowInsets(vertical: CGFloat = 6, trailingInset: CGFloat = 0) -> some View {
        modifier(CompactRowInsetsModifier(vertical: vertical, trailingInset: trailingInset))
    }
}

private struct CompactRowInsetsModifier: ViewModifier {
    let vertical: CGFloat
    let trailingInset: CGFloat

    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        let margin = Layout.margin(sizeClass)
        content.listRowInsets(EdgeInsets(top: vertical, leading: margin, bottom: vertical, trailing: margin - trailingInset))
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

/// A shelf title in Poppins, like the web's preview list headers. With a
/// route, "See more" at the trailing edge links to the full list.
struct SectionHeader: View {
    let title: String
    var route: AppRoute?
    /// The link's label, "See more" by default.
    var moreTitle: String?

    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Concrete colors: a plain list's section header dims the
            // hierarchical .primary style to grey.
            Text(title)
                .displayFont(.section)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if let route {
                NavigationLink(value: route) {
                    Text(moreTitle ?? t("generic.seeMore"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
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
            VStack(alignment: .leading, spacing: 8) {
                ArtworkImage(id: album.coverArt, cornerRadius: Layout.artworkRadius)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(album.name)
                            .lineLimit(1)
                        if album.explicitStatus == .explicit {
                            ExplicitBadge()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    HStack(spacing: 4) {
                        Text(captionText)
                            .lineLimit(1)
                        AlbumCacheBadge(albumId: album.id)
                    }
                    .font(.caption)
                    .foregroundStyle(ThemeColor.mutedForeground)
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
            VStack(alignment: .leading, spacing: 8) {
                ArtworkImage(id: playlist.coverArt, cornerRadius: Layout.artworkRadius, placeholder: "music.note.list")
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(t("playlist.songCount", count: playlist.songCount))
                            .lineLimit(1)
                        PlaylistCacheBadge(playlistId: playlist.id)
                    }
                    .font(.caption)
                    .foregroundStyle(ThemeColor.mutedForeground)
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
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

/// A horizontal, snapping row of tiles: three on a phone, like the web's
/// preview lists, with the next one peeking in, and five and a half on a
/// wide iPad window.
struct Shelf<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    /// Tenths of the width each tile takes on a phone.
    var compactSpan = 3
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
                            count: isRegular ? 11 : 10,
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

/// An adaptive grid with the page margins, for tiles: two columns on a
/// phone, as on the web.
struct TileGrid<Content: View>: View {
    var minimumWidth: CGFloat = 150
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 24
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

/// A song in a list, like the web's mobile song rows: cover or number,
/// title and artist, its download state, length and a menu. Separators
/// start at the title; swipe right to queue it in a native List.
struct SongRow: View {
    let song: Song
    var leading: SongRowLeading = .artwork
    var subtitle: SongRowSubtitle = .artist
    var showsDuration = true
    var context: SongMenuContext = .standard
    let play: () -> Void

    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t
    @Environment(\.themeContext) private var theme

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
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(ThemeColor.mutedForeground)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                SongMenuItems(song: song, context: context)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ThemeColor.mutedForeground)
                    .frame(width: 32, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(t("playlist.buttons.options", ["name": song.title]))
        }
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(theme.palette.border)
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .compactRowInsets(vertical: 4, trailingInset: 8)
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
            SongArtwork(song: song, cornerRadius: Layout.rowArtworkRadius)
                .frame(width: 44, height: 44)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: Layout.rowArtworkRadius, style: .continuous)
                            .fill(.black.opacity(0.4))
                        NowPlayingIndicator(isPlaying: player.isPlaying, size: 18)
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
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(ThemeColor.mutedForeground)
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
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
                    .lineLimit(1)
                if song.explicitStatus == .explicit {
                    ExplicitBadge()
                }
            }
            if let subtitleText {
                Text(subtitleText)
                    .font(.footnote)
                    .foregroundStyle(ThemeColor.mutedForeground)
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

/// The web's equalizer on the song that is playing: four bars bouncing
/// from the bottom, still while paused or with Reduce Motion.
struct NowPlayingIndicator: View {
    let isPlaying: Bool
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Each bar's height in the web icon's 24-point box, the scales its
    /// keyframes move between and its delay.
    private static let bars: [(height: CGFloat, from: CGFloat, to: CGFloat, delay: Double)] = [
        (14, 0.4, 0.8, 0),
        (20, 0.9, 0.4, 0.07),
        (18, 0.7, 1, 0.14),
        (12, 0.6, 1, 0.07),
    ]
    private static let period = 0.6

    var body: some View {
        let isAnimating = isPlaying && !reduceMotion
        TimelineView(.animation(paused: !isAnimating)) { context in
            Canvas { canvas, canvasSize in
                let unit = canvasSize.width / 24
                let time = context.date.timeIntervalSinceReferenceDate
                for (index, bar) in Self.bars.enumerated() {
                    var scale = bar.from
                    if isAnimating {
                        let phase = ((time - bar.delay) / Self.period).truncatingRemainder(dividingBy: 1)
                        let eased = (1 - cos(2 * .pi * phase)) / 2
                        scale = bar.from + (bar.to - bar.from) * eased
                    }
                    let height = bar.height * unit * scale
                    let rect = CGRect(
                        x: (1 + 6 * CGFloat(index)) * unit,
                        y: canvasSize.height - 2 * unit - height,
                        width: 4 * unit,
                        height: height
                    )
                    canvas.fill(Path(roundedRect: rect, cornerRadius: unit), with: .foreground)
                }
            }
        }
        .frame(width: size, height: size)
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

/// The web's action row, centered: Shuffle, the long primary Play and any
/// `trailing` actions, such as the favorite heart. Only Play sits on Liquid
/// Glass; the others are bare symbols in the accent color.
struct PlayShuffleButtons<Trailing: View>: View {
    /// False for a single song, which has nothing to shuffle.
    var canShuffle = true
    /// Centered on a phone; leading under an iPad header.
    var alignment: Alignment = .center
    let play: () -> Void
    let shuffle: () -> Void
    @ViewBuilder var trailing: Trailing

    @Environment(Localizer.self) private var t

    var body: some View {
        HStack(spacing: 20) {
            ActionIconButton(systemImage: "shuffle", label: t("shortcuts.playback.shuffle"), action: shuffle)
                .disabled(!canShuffle)
            PlayButton(label: t("options.play"), action: play)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

extension PlayShuffleButtons where Trailing == ActionSpacer {
    /// Without a trailing action, a space as wide as Shuffle keeps Play in
    /// the middle.
    init(
        canShuffle: Bool = true,
        alignment: Alignment = .center,
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void
    ) {
        self.init(canShuffle: canShuffle, alignment: alignment, play: play, shuffle: shuffle) {
            ActionSpacer()
        }
    }
}

/// An empty slot the size of an `ActionIconButton`.
struct ActionSpacer: View {
    var body: some View {
        Color.clear
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
    }
}

/// The long Play capsule in the theme's primary color, on Liquid Glass.
/// Themes with a light primary get a dark label.
struct PlayButton: View {
    let label: String
    let action: () -> Void

    @Environment(\.themeContext) private var theme

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.headline)
                .foregroundStyle(theme.palette.primaryForeground)
                .lineLimit(1)
                .frame(minWidth: 112, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// A bare symbol beside Play, for Shuffle, the heart or a download: the
/// accent color unless `foreground` says otherwise, dimmed while disabled.
struct ActionIconButton: View {
    let systemImage: String
    let label: String
    var foreground: AnyShapeStyle = AnyShapeStyle(.tint)
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}
