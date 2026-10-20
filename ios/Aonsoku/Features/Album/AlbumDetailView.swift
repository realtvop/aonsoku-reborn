import AonsokuKit
import SwiftUI

/// An album, laid out like Apple Music's album page: the cover and title
/// over the cover's glow, Play and Shuffle, the notes, the tracks by disc,
/// the release details, then more albums by the artist and in the genre.
struct AlbumDetailView: View {
    let albumId: String
    /// What the link already knew, shown while the album loads.
    var preview: Album?

    @State private var detail: AlbumDetail?
    @State private var phase = LoadPhase.idle
    @State private var loadedRevision: Int?
    @State private var comment: AttributedString?
    @State private var extras: Extras?
    @State private var palette: ArtworkPalette?

    @Environment(AppModel.self) private var app
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(NetworkMonitor.self) private var network
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale

    /// What loads after the tracks.
    private struct Extras {
        var notes: AttributedString?
        var lastFmUrl: URL?
        var moreByArtist: [Album]
        var moreInGenre: [Album]
    }

    private var album: Album? {
        detail?.album ?? preview
    }

    private var songs: [Song] {
        detail?.songs ?? []
    }

    private var margin: CGFloat {
        Layout.margin(sizeClass)
    }

    var body: some View {
        ScrollView {
            if let album {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(album)
                    if let notes = extras?.notes {
                        AboutCard(
                            title: t("album.info.about", ["name": album.name]),
                            text: notes,
                            links: extras?.lastFmUrl.map {
                                [AboutLink(title: t("album.info.lastfm"), url: $0)]
                            } ?? []
                        )
                        .pageMargins()
                        .padding(.top, 24)
                    }
                    tracks(album)
                        .padding(.top, 20)
                    if detail != nil {
                        footer(album)
                            .padding(.top, 20)
                    }
                    shelves(album)
                        .padding(.top, Layout.sectionSpacing)
                }
                .padding(.bottom, 24)
            }
        }
        .overlay {
            if album == nil {
                if case let .failed(message) = phase {
                    ErrorStateView(message: message) {
                        Task { await refreshIfNeeded() }
                    }
                } else {
                    LoadingStateView()
                }
            }
        }
        .artworkPalette(album?.coverArt, into: $palette)
        .artworkGlowBackground(palette)
        .scrollRevealedTitle(album?.name ?? "", threshold: sizeClass == .regular ? 220 : 330)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                FavoriteToolbarButton(kind: .album, id: albumId)
                Menu {
                    if let album {
                        AlbumMenuItems(album: album)
                    }
                } label: {
                    Label(
                        t("playlist.buttons.options", ["name": album?.name ?? ""]),
                        systemImage: "ellipsis"
                    )
                }
                .disabled(album == nil)
            }
        }
        .offlineBanner()
        .task(id: sync.revision) {
            await refreshIfNeeded()
        }
        .refreshable {
            if await load() {
                await loadExtras()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ album: Album) -> some View {
        if sizeClass == .regular {
            HStack(alignment: .bottom, spacing: 28) {
                cover(album)
                    .frame(width: 260)
                VStack(alignment: .leading, spacing: 4) {
                    titles(album, font: .title.bold())
                    playButtons(album)
                        .frame(maxWidth: 340)
                        .padding(.top, 18)
                }
                Spacer(minLength: 0)
            }
            .pageMargins()
            .padding(.top, 12)
        } else {
            VStack(spacing: 0) {
                cover(album)
                    .frame(maxWidth: 290)
                    .padding(.horizontal, 24)
                VStack(spacing: 4) {
                    titles(album, font: .title2.bold())
                }
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                playButtons(album)
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity)
            .pageMargins()
            .padding(.top, 8)
        }
    }

    private func cover(_ album: Album) -> some View {
        ArtworkImage(id: album.coverArt, size: .large, cornerRadius: 10)
            .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
    }

    @ViewBuilder
    private func titles(_ album: Album, font: Font) -> some View {
        Text(album.name)
            .font(font)
            .lineLimit(3)
        artistLink(album)
            .font(.title3)
            .lineLimit(2)
        details(album)
            .padding(.top, 2)
    }

    /// The artist in the tint color, linking to their page; a menu of them
    /// when the album credits several.
    @ViewBuilder
    private func artistLink(_ album: Album) -> some View {
        let credits = album.creditedArtists.filter { $0.id?.isEmpty == false }
        if credits.count > 1 {
            Menu {
                ForEach(credits, id: \.self) { credit in
                    Button(credit.name) {
                        router.navigate(to: .artist(id: credit.id ?? "", name: credit.name))
                    }
                }
            } label: {
                Text(album.artistLine)
            }
            .foregroundStyle(.tint)
        } else if let credit = credits.first, let id = credit.id {
            NavigationLink(value: AppRoute.artist(id: id, name: credit.name)) {
                Text(album.artistLine)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        } else {
            Text(album.artistLine)
                .foregroundStyle(.secondary)
        }
    }

    /// "ROCK · 2021", with the explicit and download badges. The genre
    /// links to its albums.
    private func details(_ album: Album) -> some View {
        HStack(spacing: 5) {
            if let genre = album.primaryGenre {
                NavigationLink(value: AppRoute.albums(.byGenre(genre))) {
                    Text(genre.uppercased(with: locale))
                }
                .buttonStyle(.plain)
            }
            if let year = album.year, year > 0 {
                if album.primaryGenre != nil {
                    Text(verbatim: "·")
                }
                Text(verbatim: String(year))
            }
            if album.explicitStatus == .explicit {
                ExplicitBadge()
            }
            AlbumCacheBadge(albumId: album.id)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func playButtons(_ album: Album) -> some View {
        PlayShuffleButtons(canShuffle: songs.count > 1) {
            play(album, shuffle: false)
        } shuffle: {
            play(album, shuffle: true)
        }
        .disabled(songs.isEmpty)
    }

    private func play(_ album: Album, startingAt index: Int = 0, shuffle: Bool) {
        guard !songs.isEmpty else { return }
        player.play(
            songs,
            startingAt: index,
            shuffle: shuffle,
            source: .album(album.id),
            sourceName: album.name
        )
    }

    // MARK: - Tracks

    @ViewBuilder
    private func tracks(_ album: Album) -> some View {
        if !songs.isEmpty {
            let discs = Disc.groups(of: songs, titles: album.discTitles)
            let numbersTracks = songs.contains { ($0.track ?? 0) > 0 }
            ForEach(discs) { disc in
                if discs.count > 1 {
                    discHeader(disc)
                }
                ForEach(disc.tracks) { track in
                    SongRow(
                        song: track.song,
                        leading: .number(numbersTracks ? track.song.track : track.index + 1),
                        subtitle: track.song.artistLine == album.artistLine ? .none : .artist,
                        context: .album
                    ) {
                        play(album, startingAt: track.index, shuffle: false)
                    }
                    .padding(.vertical, 5)
                    .padding(.leading, margin)
                    .padding(.trailing, margin - 8)
                    if track.id != disc.tracks.last?.id {
                        // Starts under the title, past the track number.
                        Divider()
                            .padding(.leading, margin + 38)
                    }
                }
            }
        } else if detail == nil {
            if case let .failed(message) = phase {
                ErrorStateView(message: message) {
                    Task { await refreshIfNeeded() }
                }
                .frame(minHeight: 220)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            }
        } else if album.songCount > 0, !network.isOnline {
            EmptyStateView(
                title: t("album.detail.songsUnavailableTitle"),
                systemImage: "icloud.slash",
                description: t("album.detail.songsUnavailable")
            )
            .frame(minHeight: 220)
        }
    }

    private func discHeader(_ disc: Disc) -> some View {
        HStack(spacing: 6) {
            Text(t("album.table.discNumber", ["number": String(disc.number)]))
            if let title = disc.title {
                Text(verbatim: "·")
                Text(title)
                    .lineLimit(1)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, disc.id == 0 ? 0 : 22)
        .padding(.bottom, 4)
        .pageMargins()
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Footer

    /// The release date, length, the first track's comment and the labels,
    /// in small print under the tracks.
    private func footer(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let released = releaseDate(album) {
                Text(released)
            }
            Text(
                "\(t("playlist.songCount", count: max(album.songCount, songs.count))), \(Formatters.totalDuration(album.duration, locale: locale))"
            )
            if let comment {
                Text(comment)
                    .textSelection(.enabled)
                    .padding(.top, 10)
            }
            let labels = recordLabelLines(album)
            if !labels.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(labels, id: \.self) { line in
                        Text(line)
                    }
                }
                .padding(.top, 10)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pageMargins()
    }

    private func releaseDate(_ album: Album) -> String? {
        let date = album.releaseDate ?? album.originalReleaseDate ?? ItemDate(year: album.year)
        return Formatters.releaseDate(date, locale: locale)
    }

    /// "℗ 2021 Label" for up to three labels.
    private func recordLabelLines(_ album: Album) -> [String] {
        var seen = Set<String>()
        let year = album.year.flatMap { $0 > 0 ? "\($0) " : nil } ?? ""
        return album.recordLabels
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(3)
            .map { "℗ \(year)\($0)" }
    }

    // MARK: - Shelves

    /// More by the artist and more in the genre, on a band like the one
    /// at the end of Apple Music's album pages.
    @ViewBuilder
    private func shelves(_ album: Album) -> some View {
        if let extras, !extras.moreByArtist.isEmpty || !extras.moreInGenre.isEmpty {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                if let artistId = album.artistId, !extras.moreByArtist.isEmpty {
                    shelf(
                        title: t("album.more.listTitle"),
                        route: .albums(.discography(artistId: artistId)),
                        albums: extras.moreByArtist,
                        caption: .year
                    )
                }
                if let genre = album.primaryGenre, !extras.moreInGenre.isEmpty {
                    shelf(
                        title: t("album.more.genreTitle", ["genre": genre]),
                        route: .albums(.byGenre(genre)),
                        albums: extras.moreInGenre,
                        caption: .artist
                    )
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary)
        }
    }

    private func shelf(
        title: String,
        route: AppRoute,
        albums: [Album],
        caption: AlbumTile.Caption
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, route: route)
                .pageMargins()
            AlbumShelf(albums: albums, caption: caption)
        }
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
    /// page has an album to show.
    private func load() async -> Bool {
        let repository = app.repository
        if detail == nil, let cached = await repository.cachedAlbum(id: albumId) {
            show(cached)
        }
        if detail == nil {
            phase = .loading
        }
        do {
            let loaded = try await repository.album(id: albumId)
            guard !Task.isCancelled else { return false }
            show(loaded)
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

    private func show(_ loaded: AlbumDetail) {
        detail = loaded
        let text = loaded.songs.first?.comment?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        comment = text.isEmpty ? nil : RichText.linkified(text)
    }

    private func loadExtras() async {
        guard let album else { return }
        let repository = app.repository
        let id = album.id
        async let info = repository.albumInfo(id: id)
        async let byArtist = Self.albums(byArtist: album.artistId, excluding: id, in: repository)
        async let inGenre = Self.albums(inGenre: album.primaryGenre, excluding: id, in: repository)
        let (loadedInfo, artistAlbums, genreAlbums) = await (info, byArtist, inGenre)
        guard !Task.isCancelled else { return }
        let notes = loadedInfo?.notes.map { RichText.html($0) }
        extras = Extras(
            notes: notes.flatMap { $0.characters.isEmpty ? nil : $0 },
            lastFmUrl: loadedInfo?.lastFmUrl.flatMap { Self.webURL($0) },
            moreByArtist: artistAlbums,
            moreInGenre: genreAlbums
        )
    }

    /// The artist's other albums, newest first.
    private static func albums(
        byArtist artistId: String?,
        excluding id: String,
        in repository: LibraryRepository
    ) async -> [Album] {
        guard let artistId, !artistId.isEmpty,
              let artist = try? await repository.artist(id: artistId)
        else { return [] }
        return Array(artist.albums.filter { $0.id != id }.prefix(16))
    }

    /// Other albums in the genre.
    private static func albums(
        inGenre genre: String?,
        excluding id: String,
        in repository: LibraryRepository
    ) async -> [Album] {
        guard let genre,
              let page = try? await repository.albums(.byGenre(genre), offset: 0, limit: 17)
        else { return [] }
        return Array(page.items.filter { $0.id != id }.prefix(16))
    }

    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}

/// The tracks on one disc.
private struct Disc: Identifiable {
    struct Track: Identifiable {
        /// Position in the whole album, for playback.
        let index: Int
        let song: Song

        var id: Int { index }
    }

    /// Position among the album's discs.
    let id: Int
    let number: Int
    let title: String?
    var tracks: [Track]

    /// Consecutive songs on the same disc, in album order.
    static func groups(of songs: [Song], titles: [DiscTitle]) -> [Disc] {
        var discs: [Disc] = []
        for (index, song) in songs.enumerated() {
            let number = song.discNumber ?? 1
            let track = Track(index: index, song: song)
            if discs.last?.number == number {
                discs[discs.count - 1].tracks.append(track)
            } else {
                let title = titles.first { $0.disc == number }?.title
                discs.append(Disc(
                    id: discs.count,
                    number: number,
                    title: title.flatMap { $0.isEmpty ? nil : $0 },
                    tracks: [track]
                ))
            }
        }
        return discs
    }
}

extension Album {
    /// The genre to show and link to.
    var primaryGenre: String? {
        let genre = genre ?? genres.first
        guard let genre, !genre.isEmpty else { return nil }
        return genre
    }
}
