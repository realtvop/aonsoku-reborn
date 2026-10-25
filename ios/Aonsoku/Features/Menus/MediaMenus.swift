import AonsokuKit
import SwiftUI

/// Where a song menu appears, which adds the items that only make sense
/// there.
enum SongMenuContext: Equatable {
    case standard
    /// On the album's own page, which hides "Go to album".
    case album
    /// In a playlist the user owns; `index` is the song's position in it.
    case playlist(id: String, index: Int)
    /// In the play queue.
    case queue(QueueEntry)
    /// The current song's playback menu.
    case nowPlaying
}

/// The actions for one song, for menus and context menus.
struct SongMenuItems: View {
    let song: Song
    var context: SongMenuContext = .standard

    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadsStore.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        Group {
            ControlGroup {
                FavoriteButton(kind: .song, id: song.id)
                Button {
                    router.present(.addToPlaylist([song]))
                } label: {
                    Label(t("options.playlist.add"), systemImage: "text.badge.plus")
                }
            }
            menuSections
        }
        .mediaMenuAppearance()
    }

    @ViewBuilder
    private var menuSections: some View {
        if context != .nowPlaying {
            Section {
                if case let .queue(entry) = context {
                    Button(role: .destructive) {
                        player.remove(entries: [entry])
                    } label: {
                        Label(t("options.removeFromQueue"), systemImage: "minus.circle")
                    }
                } else {
                    Button {
                        player.enqueue([song], position: .next, announcingWith: toasts)
                    } label: {
                        Label(t("options.playNext"), systemImage: QueueSymbol.playNext)
                    }
                    Button {
                        player.enqueue([song], position: .last, announcingWith: toasts)
                    } label: {
                        Label(t("options.addLast"), systemImage: QueueSymbol.playLast)
                    }
                }
            }
        }
        if case let .playlist(id, index) = context {
            Section {
                Button(role: .destructive) {
                    router.playlistSongRemoval = PlaylistSongRemoval(playlistId: id, indexes: [index])
                } label: {
                    Label(t("options.playlist.removeSong"), systemImage: "text.badge.minus")
                }
            }
        }
        if context == .nowPlaying {
            Section {
                PlaybackMenuItems()
            }
        }
        Section {
            if context != .album, let albumId = song.albumId {
                Button {
                    router.navigate(to: .album(id: albumId, preview: nil))
                } label: {
                    Label(t("options.goto.album"), systemImage: "square.stack")
                }
            }
            if let artistId = song.artistId {
                Button {
                    router.navigate(to: .artist(id: artistId, name: song.artist))
                } label: {
                    Label(t("options.goto.artist"), systemImage: "music.mic")
                }
            }
            Button {
                router.present(.songInfo(song))
            } label: {
                Label(t("options.info"), systemImage: "info.circle")
            }
        }
        Section {
            songDownloadButton
        }
    }

    @ViewBuilder
    private var songDownloadButton: some View {
        let _ = downloads.revision
        switch downloads.state(ofSong: song.id) {
        case .cached(.explicit, _), .downloading:
            Button(role: .destructive) {
                Task { await downloads.remove(songIds: [song.id]) }
            } label: {
                Label(t("options.removeDownload"), systemImage: "trash")
            }
        default:
            Button {
                Task { await downloads.download(songs: [song]) }
            } label: {
                Label(t("options.download"), systemImage: "arrow.down.circle")
            }
        }
    }

}

/// Playback-specific actions shared by the song and radio menus.
private struct PlaybackMenuItems: View {
    @Environment(PlayerStore.self) private var player
    @Environment(Router.self) private var router
    @Environment(Localizer.self) private var t

    var body: some View {
        SleepTimerMenu {
            Label(t("player.sleepTimer.title"), systemImage: "moon.zzz")
        }
        if player.currentSong != nil {
            Button {
                router.present(.lyricsSettings)
            } label: {
                Label(t("fullscreen.selectLyrics"), systemImage: "quote.bubble")
            }
        }
    }
}

/// Uses the same song actions and appearance as library context menus.
struct NowPlayingMenuItems: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        Group {
            if let song = player.currentSong {
                SongMenuItems(song: song, context: .nowPlaying)
            } else {
                Section {
                    PlaybackMenuItems()
                }
            }
        }
        .mediaMenuAppearance()
    }
}

extension View {
    /// Menu controls use system colors, independently of the player's white
    /// foreground and the app's themed control tint. Destructive roles stay red.
    func mediaMenuAppearance() -> some View {
        foregroundStyle(.primary)
            .tint(nil)
            .symbolRenderingMode(.monochrome)
            .buttonStyle(.automatic)
    }
}

/// The actions for an album.
struct AlbumMenuItems: View {
    let album: Album
    var showsArtistLink = true

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(PinnedHomeStore.self) private var pinned
    @Environment(DownloadsStore.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        Section {
            Button {
                Task { await player.playAlbum(id: album.id) }
            } label: {
                Label(t("options.play"), systemImage: "play")
            }
            Button {
                Task { await player.playAlbum(id: album.id, shuffle: true) }
            } label: {
                Label(t("shortcuts.playback.shuffle"), systemImage: "shuffle")
            }
            Button {
                withSongs { player.enqueue($0, position: .next, announcingWith: toasts) }
            } label: {
                Label(t("options.playNext"), systemImage: QueueSymbol.playNext)
            }
            Button {
                withSongs { player.enqueue($0, position: .last, announcingWith: toasts) }
            } label: {
                Label(t("options.addLast"), systemImage: QueueSymbol.playLast)
            }
        }
        Section {
            Button {
                withSongs { router.present(.addToPlaylist($0)) }
            } label: {
                Label(t("options.playlist.add"), systemImage: "text.badge.plus")
            }
            PinButton(itemId: album.id, kind: .album)
            FavoriteButton(kind: .album, id: album.id)
            collectionDownloadButton
        }
        if showsArtistLink, let artistId = album.artistId {
            Button {
                router.navigate(to: .artist(id: artistId, name: album.artist))
            } label: {
                Label(t("options.goto.artist"), systemImage: "music.mic")
            }
        }
    }

    @ViewBuilder
    private var collectionDownloadButton: some View {
        let _ = downloads.revision
        switch downloads.state(ofAlbum: album.id) {
        case .notCached:
            Button {
                Task { await downloads.download(albumId: album.id) }
            } label: {
                Label(t("options.downloadAlbum"), systemImage: "arrow.down.circle")
            }
        case .downloading, .cached:
            Button(role: .destructive) {
                Task { await downloads.remove(albumId: album.id) }
            } label: {
                Label(t("options.removeDownload"), systemImage: "trash")
            }
        }
    }

    private func withSongs(_ action: @escaping ([Song]) -> Void) {
        Task {
            do {
                action(try await app.repository.album(id: album.id).songs)
            } catch {
                toasts.show(error: error)
            }
        }
    }
}

/// The actions for a playlist. Editing and deleting are offered only for
/// the user's own playlists.
struct PlaylistMenuItems: View {
    let playlist: Playlist

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadsStore.self) private var downloads
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        Section {
            Button {
                Task { await player.playPlaylist(id: playlist.id) }
            } label: {
                Label(t("options.play"), systemImage: "play")
            }
            Button {
                Task { await player.playPlaylist(id: playlist.id, shuffle: true) }
            } label: {
                Label(t("shortcuts.playback.shuffle"), systemImage: "shuffle")
            }
            Button {
                withSongs { player.enqueue($0, position: .next, announcingWith: toasts) }
            } label: {
                Label(t("options.playNext"), systemImage: QueueSymbol.playNext)
            }
            Button {
                withSongs { player.enqueue($0, position: .last, announcingWith: toasts) }
            } label: {
                Label(t("options.addLast"), systemImage: QueueSymbol.playLast)
            }
        }
        Section {
            PinButton(itemId: playlist.id, kind: .playlist)
            collectionDownloadButton
        }
        if playlist.isOwned(by: session.account?.username) {
            Section {
                Button {
                    router.present(.editPlaylist(playlist))
                } label: {
                    Label(t("options.playlist.edit"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    router.playlistPendingDeletion = playlist
                } label: {
                    Label(t("options.playlist.delete"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var collectionDownloadButton: some View {
        let _ = downloads.revision
        switch downloads.state(ofPlaylist: playlist.id) {
        case .notCached:
            Button {
                Task { await downloads.download(playlistId: playlist.id) }
            } label: {
                Label(t("options.downloadPlaylist"), systemImage: "arrow.down.circle")
            }
        case .downloading, .cached:
            Button(role: .destructive) {
                Task { await downloads.remove(playlistId: playlist.id) }
            } label: {
                Label(t("options.removeDownload"), systemImage: "trash")
            }
        }
    }

    private func withSongs(_ action: @escaping ([Song]) -> Void) {
        Task {
            do {
                action(try await app.repository.playlist(id: playlist.id).songs)
            } catch {
                toasts.show(error: error)
            }
        }
    }
}

/// The actions for an artist.
struct ArtistMenuItems: View {
    let artist: Artist

    @Environment(AppModel.self) private var app
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadsStore.self) private var downloads
    @Environment(ToastCenter.self) private var toasts
    @Environment(Localizer.self) private var t

    var body: some View {
        Section {
            Button {
                Task { await player.playArtist(id: artist.id, name: artist.name) }
            } label: {
                Label(t("options.play"), systemImage: "play")
            }
            Button {
                Task { await player.playArtist(id: artist.id, name: artist.name, shuffle: true) }
            } label: {
                Label(t("shortcuts.playback.shuffle"), systemImage: "shuffle")
            }
            Button {
                withSongs { player.enqueue($0, position: .next, announcingWith: toasts) }
            } label: {
                Label(t("options.playNext"), systemImage: QueueSymbol.playNext)
            }
            Button {
                withSongs { player.enqueue($0, position: .last, announcingWith: toasts) }
            } label: {
                Label(t("options.addLast"), systemImage: QueueSymbol.playLast)
            }
        }
        Section {
            FavoriteButton(kind: .artist, id: artist.id)
            Button {
                Task { await downloads.download(artistId: artist.id) }
            } label: {
                Label(t("options.downloadArtist"), systemImage: "arrow.down.circle")
            }
        }
    }

    /// Every song by the artist, newest first, like the web
    /// `getArtistAllSongs`.
    private func withSongs(_ action: @escaping ([Song]) -> Void) {
        let query = SongListQuery(scope: .artist(id: artist.id, name: artist.name))
        Task {
            do {
                action(try await app.repository.songs(query, offset: 0, limit: 10_000).items)
            } catch {
                toasts.show(error: error)
            }
        }
    }
}

/// Like or Unlike.
struct FavoriteButton: View {
    let kind: FavoriteKind
    let id: String

    @Environment(FavoritesStore.self) private var favorites
    @Environment(Localizer.self) private var t

    var body: some View {
        let isFavorite = favorites.isFavorite(kind, id: id)
        Button {
            Task { await favorites.toggle(kind, id: id) }
        } label: {
            Label(
                t(isFavorite ? "options.unlike" : "options.like"),
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
    }
}

/// Pin to or unpin from Home.
struct PinButton: View {
    let itemId: String
    let kind: PinnedItem.Kind

    @Environment(PinnedHomeStore.self) private var pinned
    @Environment(Localizer.self) private var t

    var body: some View {
        let isPinned = pinned.isPinned(itemId, kind: kind)
        Button {
            pinned.toggle(itemId, kind: kind)
        } label: {
            Label(t(isPinned ? "options.unpin" : "options.pin"), systemImage: isPinned ? "pin.slash" : "pin")
        }
    }
}

extension Playlist {
    /// Whether `username` may edit the playlist. Playlists without an owner
    /// are treated as editable, as the web does.
    func isOwned(by username: String?) -> Bool {
        guard let owner, !owner.isEmpty else { return true }
        return owner == username
    }
}
