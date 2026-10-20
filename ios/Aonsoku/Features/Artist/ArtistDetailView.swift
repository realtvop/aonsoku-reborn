import AonsokuKit
import SwiftUI

/// An artist, laid out like Apple Music's artist page: the portrait across
/// the top with the name and Play over it, then the latest release, the top
/// songs, the albums, the biography and similar artists.
struct ArtistDetailView: View {
    let artistId: String
    /// The name from the link, shown while the artist loads.
    let name: String

    @State private var detail: ArtistDetail?
    @State private var phase = LoadPhase.idle
    @State private var loadedRevision: Int?
    @State private var extras: Extras?
    @State private var heroHeight: CGFloat = 420
    @State private var isPastHero = false

    @ScaledMetric(relativeTo: .largeTitle) private var nameSize: CGFloat = 34

    @Environment(AppModel.self) private var app
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(NetworkMonitor.self) private var network
    @Environment(PlayerStore.self) private var player
    @Environment(Localizer.self) private var t
    @Environment(\.themeContext) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(artistId: String, name: String) {
        self.artistId = artistId
        self.name = name
    }

    /// What loads after the artist.
    private struct Extras {
        var biography: AttributedString?
        var links: [AboutLink]
        var topSongs: [Song]
        var similar: [Artist]
    }

    private var artist: Artist? {
        detail?.artist
    }

    private var albums: [Album] {
        detail?.albums ?? []
    }

    private var artistName: String {
        artist?.name ?? name
    }

    private var albumCount: Int {
        max(artist?.albumCount ?? 0, albums.count)
    }

    private var songCount: Int {
        albums.reduce(0) { $0 + $1.songCount }
    }

    private var songsRoute: AppRoute {
        .songs(SongListQuery(scope: .artist(id: artistId, name: artistName)))
    }

    private var discographyRoute: AppRoute {
        .albums(.discography(artistId: artistId))
    }

    /// How far the page scrolls before the name passes under the bar.
    private var titleThreshold: CGFloat {
        heroHeight - 120
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                if detail != nil {
                    sections
                        .padding(.vertical, 24)
                } else {
                    placeholder
                }
            }
        }
        // The portrait runs under the status and navigation bars.
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectHidden(!isPastHero, for: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > titleThreshold
        } action: { _, isPast in
            isPastHero = isPast
        }
        .scrollRevealedTitle(artistName, threshold: titleThreshold)
        .themedBackground()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                FavoriteToolbarButton(kind: .artist, id: artistId)
                Menu {
                    if let artist {
                        ArtistMenuItems(artist: artist)
                    }
                } label: {
                    Label(
                        t("artist.buttons.options", ["artist": artistName]),
                        systemImage: "ellipsis"
                    )
                }
                .disabled(artist == nil)
            }
        }
        .offlineBanner()
        .task(id: sync.revision) {
            await refreshIfNeeded()
        }
    }

    // MARK: - Hero

    /// The portrait with the name and the play buttons over its lower edge.
    /// Pulling the page down stretches it.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            heroArtwork
            heroCaption
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { height, _ in
            min(max(height * 0.55, 300), 520)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            heroHeight = height
        }
    }

    private var heroArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.5), Color(white: 0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "music.mic")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            ArtworkBackdrop(id: artist?.coverArt, size: .large, focus: UnitPoint(x: 0.5, y: 0.3))
        }
        .overlay {
            // Keeps the white name legible on light portraits.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.6), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .visualEffect { content, proxy in
            // Grows from the bottom edge into the gap above it.
            let pull = proxy.frame(in: .scrollView(axis: .vertical)).minY
            let height = max(proxy.size.height, 1)
            return content.scaleEffect(pull > 0 ? 1 + pull / height : 1, anchor: .bottom)
        }
        .accessibilityHidden(true)
    }

    private var heroCaption: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(artistName)
                    .font(.system(
                        size: sizeClass == .regular ? nameSize * 1.4 : nameSize,
                        weight: .bold
                    ))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
                if albumCount > 0 {
                    stats
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
            if albumCount > 0 {
                playButtons
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .pageMargins()
        .padding(.bottom, 20)
        .animation(.smooth, value: albumCount > 0)
    }

    /// "12 albums · 148 songs", linking to the discography and the songs.
    private var stats: some View {
        HStack(spacing: 6) {
            NavigationLink(value: discographyRoute) {
                Text(t("artist.info.albumsCount", count: albumCount))
            }
            if songCount > 0 {
                Text(verbatim: "·")
                NavigationLink(value: songsRoute) {
                    Text(t("playlist.songCount", count: songCount))
                }
            }
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
    }

    private var playButtons: some View {
        HStack(spacing: 12) {
            Button {
                play(shuffle: true)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(t("playlist.buttons.shuffle", ["name": artistName]))
            Button {
                play(shuffle: false)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .frame(width: 30, height: 30)
                    // Themes with a white accent need a dark symbol.
                    .foregroundStyle(theme.palette.primaryForeground)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel(t("playlist.buttons.play", ["name": artistName]))
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    /// Every song by the artist, like the web artist buttons.
    private func play(shuffle: Bool) {
        Task { await player.playArtist(id: artistId, name: artistName, shuffle: shuffle) }
    }

    // MARK: - Sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            if let latest = latestRelease {
                LatestReleaseCard(album: latest)
                    .pageMargins()
            }
            if let topSongs = extras?.topSongs, !topSongs.isEmpty {
                section(t("artist.topSongs"), route: songsRoute) {
                    SongColumns(songs: topSongs) { index in
                        player.play(
                            topSongs,
                            startingAt: index,
                            source: .artist(artistId),
                            sourceName: artistName
                        )
                    }
                }
            }
            if !albums.isEmpty {
                section(t("artist.recentAlbums"), route: discographyRoute) {
                    AlbumShelf(albums: Array(albums.prefix(20)), caption: .year)
                }
            }
            if let biography = extras?.biography {
                AboutCard(
                    title: t("album.info.about", ["name": artistName]),
                    text: biography,
                    links: extras?.links ?? []
                )
                .pageMargins()
            }
            if let similar = extras?.similar, !similar.isEmpty {
                section(t("artist.relatedArtists")) {
                    Shelf(items: similar, compactSpan: 3) { similarArtist in
                        ArtistTile(artist: similarArtist)
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        route: AppRoute? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, route: route)
                .pageMargins()
            content()
        }
    }

    /// The newest album, when the dates say which one that is and the
    /// artist has more than one.
    private var latestRelease: Album? {
        guard albums.count > 1, let newest = albums.first, (newest.year ?? 0) > 0 else {
            return nil
        }
        return newest
    }

    /// The first load, or why it failed, under the portrait.
    private var placeholder: some View {
        Group {
            if case let .failed(message) = phase {
                ErrorStateView(message: message) {
                    Task { await refreshIfNeeded() }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - Loading

    /// Loads once per library revision, so returning to the page does not
    /// reload it but a finished sync does.
    private func refreshIfNeeded() async {
        let revision = sync.revision
        guard loadedRevision != revision else { return }
        guard await load() else { return }
        loadedRevision = revision
        if extras == nil {
            await loadExtras()
        }
    }

    /// Shows the local copy at once, then the server's. Returns whether the
    /// page has an artist to show.
    private func load() async -> Bool {
        let repository = app.repository
        if detail == nil, let cached = await repository.cachedArtist(id: artistId) {
            detail = cached
        }
        if detail == nil {
            phase = .loading
        }
        do {
            let loaded = try await repository.artist(id: artistId)
            guard !Task.isCancelled else { return false }
            detail = loaded
            phase = .loaded
            return true
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return false }
            guard detail != nil else {
                phase = .failed(network.isOnline ? error.localizedDescription : t("offline.disconnected"))
                return false
            }
            // The local copy stays.
            phase = .loaded
            return true
        }
    }

    private func loadExtras() async {
        let repository = app.repository
        let id = artistId
        async let info = repository.artistInfo(id: id)
        async let top = repository.topSongs(artistName: artistName, count: 10)
        let (loadedInfo, topSongs) = await (info, top)
        guard !Task.isCancelled else { return }
        let biography = loadedInfo?.biography.map { RichText.html($0) }
        extras = Extras(
            biography: biography.flatMap { $0.characters.isEmpty ? nil : $0 },
            links: links(loadedInfo),
            topSongs: topSongs,
            similar: Array((loadedInfo?.similarArtists ?? []).filter { $0.id != id }.prefix(16))
        )
    }

    /// Last.fm and MusicBrainz, under the biography.
    private func links(_ info: ArtistInfo?) -> [AboutLink] {
        var links: [AboutLink] = []
        if let url = info?.lastFmUrl.flatMap({ AlbumDetailView.webURL($0) }) {
            links.append(AboutLink(title: t("album.info.lastfm"), url: url))
        }
        let musicBrainzId = [artist?.musicBrainzId, info?.musicBrainzId]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        if let musicBrainzId,
           let url = URL(string: "https://musicbrainz.org/artist/\(musicBrainzId)") {
            links.append(AboutLink(title: t("album.info.musicbrainz"), url: url))
        }
        return links
    }
}

// MARK: - Latest release

/// The artist's newest album, above the top songs.
private struct LatestReleaseCard: View {
    let album: Album

    @Environment(Localizer.self) private var t
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationLink(value: AppRoute.album(album)) {
            HStack(spacing: 14) {
                ArtworkImage(id: album.coverArt, cornerRadius: 8)
                    .frame(width: 96)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("native.artist.latestRelease"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    HStack(spacing: 4) {
                        Text(album.name)
                            .lineLimit(2)
                        if album.explicitStatus == .explicit {
                            ExplicitBadge()
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .contextMenu {
            AlbumMenuItems(album: album, showsArtistLink: false)
        }
    }

    /// "March 3, 2021 · 12 songs".
    private var details: String {
        let date = album.releaseDate ?? album.originalReleaseDate ?? ItemDate(year: album.year)
        return [
            Formatters.releaseDate(date, locale: locale),
            album.songCount > 0 ? t("playlist.songCount", count: album.songCount) : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

// MARK: - Top songs

/// Songs in columns of four that page sideways, like Apple Music's Top
/// Songs.
private struct SongColumns: View {
    let songs: [Song]
    let play: (Int) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let rows = max(1, min(4, songs.count))
        let isRegular = sizeClass == .regular
        ScrollView(.horizontal) {
            LazyHGrid(
                rows: Array(repeating: GridItem(.fixed(58), spacing: 0), count: rows),
                spacing: Layout.shelfSpacing
            ) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    SongRow(song: song, subtitle: .album, showsDuration: false) {
                        play(index)
                    }
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        // Between rows, starting under the title.
                        if index % rows != rows - 1, index != songs.count - 1 {
                            Divider()
                                .padding(.leading, 60)
                        }
                    }
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
        .contentMargins(.horizontal, Layout.margin(sizeClass), for: .scrollContent)
    }
}
