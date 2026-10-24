import AonsokuKit
import SwiftUI

/// A playlist, laid out like the web's playlist page: the cover, name and
/// description over a band of the cover's color, Shuffle, Play and the
/// download button, then the songs in playlist order and their total
/// length. A list, so songs can be swiped away.
struct PlaylistDetailView: View {
    let playlistId: String

    @State private var detail: PlaylistDetail?
    @State private var phase = LoadPhase.idle
    @State private var loadedKey: ReloadKey?
    @State private var palette: ArtworkPalette?
    @State private var isDescriptionExpanded = false
    @State private var headerHeight: CGFloat = 360

    @Environment(AppModel.self) private var app
    @Environment(LibrarySyncStore.self) private var sync
    @Environment(NetworkMonitor.self) private var network
    @Environment(PlayerStore.self) private var player
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.locale) private var locale

    /// A finished sync or an edit to any playlist reloads the page.
    private struct ReloadKey: Equatable {
        var library: Int
        var playlists: Int
    }

    private var reloadKey: ReloadKey {
        ReloadKey(library: sync.revision, playlists: playlists.revision)
    }

    /// The loaded playlist, or the one in the playlist list while it loads.
    private var playlist: Playlist? {
        detail?.playlist ?? playlists.playlists.first { $0.id == playlistId }
    }

    private var songs: [Song] {
        detail?.songs ?? []
    }

    private var isOwned: Bool {
        playlist?.isOwned(by: session.account?.username) ?? false
    }

    /// Empty playlists show the placeholder, as on the web.
    private var coverArt: String? {
        guard let playlist, playlist.songCount > 0 || !songs.isEmpty else { return nil }
        return playlist.coverArt
    }

    private var margin: CGFloat {
        Layout.margin(sizeClass)
    }

    var body: some View {
        List {
            if let playlist {
                header(playlist)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        headerHeight = height
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                playButtons(playlist)
                    .listRowInsets(EdgeInsets(top: 8, leading: margin, bottom: 12, trailing: margin))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                songRows(playlist)
                footer
            }
        }
        .listStyle(.plain)
        .overlay {
            if playlist == nil {
                if case let .failed(message) = phase {
                    ErrorStateView(message: message) {
                        Task { await refreshIfNeeded() }
                    }
                } else {
                    LoadingStateView()
                }
            }
        }
        .artworkPalette(coverArt, into: $palette)
        .detailBand(palette, headerHeight: headerHeight)
        .themedBackground()
        .scrollRevealedTitle(playlist?.name ?? "", threshold: sizeClass == .regular ? 200 : 290)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let playlist {
                        PlaylistMenuItems(playlist: playlist)
                    }
                } label: {
                    Label(
                        t("playlist.buttons.options", ["name": playlist?.name ?? ""]),
                        systemImage: "ellipsis"
                    )
                }
                .disabled(playlist == nil)
            }
        }
        .offlineBanner()
        .task(id: reloadKey) {
            await refreshIfNeeded()
        }
        .refreshable {
            await load()
        }
    }

    // MARK: - Header

    private func header(_ playlist: Playlist) -> some View {
        DetailHeader(
            kind: t("playlist.headline"),
            title: playlist.name,
            metadata: metadata(playlist),
            palette: palette,
            drawsBand: false
        ) {
            ArtworkImage(id: coverArt, size: .large, cornerRadius: Layout.artworkRadius, placeholder: "music.note.list")
        } subtitle: {
            description(playlist)
        }
    }

    /// The owner of a shared playlist, its length and whether it is
    /// public, like the web's header badges.
    private func metadata(_ playlist: Playlist) -> [MetadataItem] {
        var items: [MetadataItem] = []
        if let owner = playlist.owner, !owner.isEmpty, !isOwned {
            items.append(MetadataItem(text: owner))
        }
        let count = songs.isEmpty ? playlist.songCount : songs.count
        if count > 0 {
            items.append(MetadataItem(text: t("playlist.songCount", count: count)))
        }
        let duration = songs.isEmpty ? playlist.duration : songs.reduce(0) { $0 + $1.duration }
        if duration > 0 {
            items.append(MetadataItem(text: Formatters.totalDuration(duration, locale: locale)))
        }
        if playlist.isPublic {
            items.append(MetadataItem(text: t("playlist.form.labels.isPublic")))
        }
        return items
    }

    private func playButtons(_ playlist: Playlist) -> some View {
        PlayShuffleButtons(
            canShuffle: songs.count > 1,
            alignment: sizeClass == .regular ? .leading : .center
        ) {
            play(playlist, shuffle: false)
        } shuffle: {
            play(playlist, shuffle: true)
        } trailing: {
            PlaylistDownloadButton(playlistId: playlist.id)
        }
        .disabled(songs.isEmpty)
    }

    /// The comment in two lines at first; a tap shows all of it.
    @ViewBuilder
    private func description(_ playlist: Playlist) -> some View {
        let text = playlist.comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            Text(RichText.linkified(text))
                .font(.subheadline)
                .opacity(0.8)
                .lineLimit(isDescriptionExpanded ? nil : 2)
                .contentShape(.rect)
                .onTapGesture {
                    withAnimation(.smooth) {
                        isDescriptionExpanded.toggle()
                    }
                }
        }
    }

    private func play(_ playlist: Playlist, startingAt index: Int = 0, shuffle: Bool) {
        guard !songs.isEmpty else { return }
        player.play(
            songs,
            startingAt: index,
            shuffle: shuffle,
            source: .playlist(playlist.id),
            sourceName: playlist.name
        )
    }

    // MARK: - Songs

    @ViewBuilder
    private func songRows(_ playlist: Playlist) -> some View {
        if !songs.isEmpty {
            // By position: a playlist can hold the same song twice.
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongRow(
                    song: song,
                    showsDuration: sizeClass == .regular,
                    context: isOwned ? .playlist(id: playlist.id, index: index) : .standard
                ) {
                    play(playlist, startingAt: index, shuffle: false)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if isOwned {
                        // The row stays until the removal is confirmed.
                        Button {
                            router.playlistSongRemoval = PlaylistSongRemoval(
                                playlistId: playlist.id,
                                indexes: [index]
                            )
                        } label: {
                            Label(t("options.playlist.removeSong"), systemImage: "minus.circle")
                        }
                        .tint(.red)
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: margin, bottom: 4, trailing: margin - 8))
                .listRowBackground(Color.clear)
            }
        } else {
            Group {
                if detail == nil {
                    if case let .failed(message) = phase {
                        ErrorStateView(message: message) {
                            Task { await refreshIfNeeded() }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                } else if playlist.songCount > 0, !network.isOnline {
                    EmptyStateView(
                        title: t("album.detail.songsUnavailableTitle"),
                        systemImage: "icloud.slash",
                        description: t("album.detail.songsUnavailable")
                    )
                } else {
                    EmptyStateView(
                        title: t("native.songs.empty"),
                        systemImage: "music.note.list",
                        description: t("playlist.noSongList")
                    )
                }
            }
            .frame(minHeight: 220)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }

    /// "24 songs, 1 hr 32 min".
    @ViewBuilder
    private var footer: some View {
        if !songs.isEmpty {
            let duration = songs.reduce(0) { $0 + $1.duration }
            Text("\(t("playlist.songCount", count: songs.count)), \(Formatters.totalDuration(duration, locale: locale))")
                .font(.footnote)
                .foregroundStyle(ThemeColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: margin, bottom: 0, trailing: margin))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Loading

    /// Loads once per library sync and playlist edit, so returning to the
    /// page does not reload it.
    private func refreshIfNeeded() async {
        let key = reloadKey
        guard loadedKey != key else { return }
        guard await load() else { return }
        loadedKey = key
    }

    /// Shows the local copy at once, then the server's. Returns whether the
    /// page has a playlist to show.
    @discardableResult
    private func load() async -> Bool {
        let repository = app.repository
        if detail == nil, let cached = await repository.cachedPlaylist(id: playlistId) {
            detail = cached
        }
        if detail == nil {
            phase = .loading
        }
        do {
            let loaded = try await repository.playlist(id: playlistId)
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
}
