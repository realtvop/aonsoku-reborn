package github.realtvop.aonsoku.ui.overlays

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.automirrored.rounded.PlaylistAdd
import androidx.compose.material.icons.automirrored.rounded.PlaylistPlay
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PlaylistRemove
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalUriHandler
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.settings.PinnedHomeItem
import github.realtvop.aonsoku.theme.LikedColor
import github.realtvop.aonsoku.ui.components.ActionDivider
import github.realtvop.aonsoku.ui.components.ActionItem
import github.realtvop.aonsoku.ui.components.ActionSheet
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.SheetHeader
import github.realtvop.aonsoku.ui.components.humanDuration
import github.realtvop.aonsoku.ui.components.songCoverArt
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** True while nothing was queued manually; "add last" then equals "play next". */
@Composable
private fun rememberUserQueueEmpty(): Boolean {
    val player = LocalAppGraph.current.player
    val flow = remember(player) {
        player.state.map { it.userQueue.isEmpty() }.distinctUntilChanged()
    }
    val empty by flow.collectAsStateWithLifecycle(true)
    return empty
}

@Composable
private fun rememberStarred(id: String, loaded: Boolean): Boolean {
    val library = LocalAppGraph.current.library
    val overrides by library.starredOverrides.collectAsStateWithLifecycle()
    return overrides[id] ?: loaded
}

@Composable
private fun rememberPinned(item: PinnedHomeItem): Boolean {
    val settings by LocalAppGraph.current.settings.state.collectAsStateWithLifecycle()
    return item in settings.pinnedHome
}

@Composable
fun SongMenuSheet(overlay: Overlay.SongMenu, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val song = overlay.song
    val playerState by graph.player.state.collectAsStateWithLifecycle()
    val isCurrent = !playerState.isRadio && playerState.current?.id == song.id
    val starredInLibrary = rememberStarred(song.id, song.isStarred)
    val starred = if (isCurrent) playerState.isCurrentStarred else starredInLibrary
    val userQueueEmpty = playerState.userQueue.isEmpty()

    ActionSheet(
        onDismiss = controller::dismiss,
        header = {
            SheetHeader(
                title = song.title,
                subtitle = song.artistLabel,
                art = songCoverArt(song),
                kind = CoverKind.Song,
            )
        },
    ) {
        ActionItem(
            icon = if (starred) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            label = t(if (starred) "options.unlike" else "options.like"),
            iconTint = if (starred) LikedColor else null,
            onClick = { graph.player.setSongStarred(song, !starred) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistPlay,
            label = t("options.playNext"),
            onClick = { graph.player.addToQueueNext(listOf(song)) },
        )
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistAdd,
            label = t("options.addLast"),
            enabled = !userQueueEmpty,
            onClick = { graph.player.addToQueueLast(listOf(song)) },
        )
        if (overlay.queueRemove != null) {
            ActionItem(
                icon = Icons.Rounded.PlaylistRemove,
                label = t("options.removeFromQueue"),
                onClick = overlay.queueRemove,
            )
        }
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.Add,
            label = t("options.playlist.add"),
            onClick = {
                controller.show(Overlay.AddToPlaylist(song.title, songIds = listOf(song.id)))
            },
        )
        if (overlay.playlistId != null && overlay.playlistIndex != null) {
            ActionItem(
                icon = Icons.Rounded.Delete,
                label = t("options.playlist.removeSong"),
                destructive = true,
                onClick = {
                    controller.show(
                        Overlay.RemoveFromPlaylist(
                            overlay.playlistId,
                            listOf(overlay.playlistIndex),
                        ),
                    )
                },
            )
        }
        if (!song.artistId.isNullOrEmpty() || !song.albumId.isNullOrEmpty()) {
            ActionDivider()
            song.artistId?.takeIf { it.isNotEmpty() }?.let { artistId ->
                ActionItem(
                    icon = Icons.Rounded.Person,
                    label = t("options.goto.artist"),
                    onClick = { navigator.open(ArtistRoute(artistId)) },
                )
            }
            song.albumId?.takeIf { it.isNotEmpty() }?.let { albumId ->
                ActionItem(
                    icon = Icons.Rounded.Album,
                    label = t("options.goto.album"),
                    onClick = { navigator.open(AlbumRoute(albumId)) },
                )
            }
        }
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.Info,
            label = t("options.info"),
            onClick = { controller.show(Overlay.SongInfo(song.id)) },
        )
    }
}

@Composable
fun AlbumMenuSheet(overlay: Overlay.AlbumMenu, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val album = overlay.album
    val starred = rememberStarred(album.id, album.isStarred)
    val userQueueEmpty = rememberUserQueueEmpty()
    val pin = PinnedHomeItem(album.id, "album")
    val pinned = rememberPinned(pin)

    ActionSheet(
        onDismiss = controller::dismiss,
        header = {
            SheetHeader(
                title = album.name,
                subtitle = album.artistLabel,
                art = CoverArt(album.coverArt ?: album.id),
            )
        },
    ) {
        ActionItem(
            icon = if (starred) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            label = t(
                if (starred) "album.buttons.dislike" else "album.buttons.like",
                "name" to album.name,
            ),
            iconTint = if (starred) LikedColor else null,
            onClick = { graph.actions.setAlbumStarred(album.id, !starred) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistPlay,
            label = t("options.playNext"),
            onClick = { graph.actions.queueAlbum(album, next = true) },
        )
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistAdd,
            label = t("options.addLast"),
            enabled = !userQueueEmpty,
            onClick = { graph.actions.queueAlbum(album, next = false) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.Add,
            label = t("options.playlist.add"),
            onClick = { controller.show(Overlay.AddToPlaylist(album.name, album = album)) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.PushPin,
            label = t(if (pinned) "options.unpin" else "options.pin"),
            onClick = { graph.actions.togglePin(pin) },
        )
    }
}

@Composable
fun ArtistMenuSheet(overlay: Overlay.ArtistMenu, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val artist = overlay.artist
    val starred = rememberStarred(artist.id, artist.isStarred)
    val userQueueEmpty = rememberUserQueueEmpty()

    ActionSheet(
        onDismiss = controller::dismiss,
        header = {
            SheetHeader(
                title = artist.name,
                subtitle = plural("artist.info.albumsCount", artist.albumCount),
                art = CoverArt(artist.coverArt ?: artist.id),
                kind = CoverKind.Artist,
            )
        },
    ) {
        ActionItem(
            icon = if (starred) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            label = t(
                if (starred) "album.buttons.dislike" else "album.buttons.like",
                "name" to artist.name,
            ),
            iconTint = if (starred) LikedColor else null,
            onClick = { graph.actions.setArtistStarred(artist.id, !starred) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistPlay,
            label = t("options.playNext"),
            onClick = { graph.actions.queueArtist(artist, next = true) },
        )
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistAdd,
            label = t("options.addLast"),
            enabled = !userQueueEmpty,
            onClick = { graph.actions.queueArtist(artist, next = false) },
        )
    }
}

@Composable
fun PlaylistMenuSheet(overlay: Overlay.PlaylistMenu, controller: OverlayController) {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val playlist = overlay.playlist
    val userQueueEmpty = rememberUserQueueEmpty()
    val pin = PinnedHomeItem(playlist.id, "playlist")
    val pinned = rememberPinned(pin)
    val hasSongs = playlist.songCount > 0

    ActionSheet(
        onDismiss = controller::dismiss,
        header = {
            val details = buildList {
                add(t("playlist.headline"))
                if (hasSongs) add(plural("playlist.songCount", playlist.songCount))
                if (playlist.duration > 0) {
                    add(
                        t(
                            "playlist.duration",
                            "duration" to strings.humanDuration(playlist.duration),
                        ),
                    )
                }
            }
            SheetHeader(
                title = playlist.name,
                subtitle = details.joinToString(" • "),
                art = CoverArt(playlist.coverArt?.takeIf { hasSongs }),
                kind = CoverKind.Playlist,
            )
        },
    ) {
        if (overlay.showPlay) {
            ActionItem(
                icon = Icons.Rounded.PlayArrow,
                label = t("options.play"),
                enabled = hasSongs,
                onClick = { graph.actions.playPlaylist(playlist) },
            )
        }
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistPlay,
            label = t("options.playNext"),
            enabled = hasSongs,
            onClick = { graph.actions.queuePlaylist(playlist, next = true) },
        )
        ActionItem(
            icon = Icons.AutoMirrored.Rounded.PlaylistAdd,
            label = t("options.addLast"),
            enabled = hasSongs && !userQueueEmpty,
            onClick = { graph.actions.queuePlaylist(playlist, next = false) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.PushPin,
            label = t(if (pinned) "options.unpin" else "options.pin"),
            onClick = { graph.actions.togglePin(pin) },
        )
        ActionDivider()
        ActionItem(
            icon = Icons.Rounded.Edit,
            label = t("options.playlist.edit"),
            onClick = { controller.show(Overlay.PlaylistForm(playlist)) },
        )
        ActionItem(
            icon = Icons.Rounded.Delete,
            label = t("options.playlist.delete"),
            destructive = true,
            onClick = { controller.show(Overlay.DeletePlaylist(playlist, overlay.onDeleted)) },
        )
    }
}

@Composable
fun RadioMenuSheet(overlay: Overlay.RadioMenu, controller: OverlayController) {
    val radio = overlay.radio
    val uriHandler = LocalUriHandler.current

    ActionSheet(
        onDismiss = controller::dismiss,
        header = {
            SheetHeader(
                title = radio.name,
                subtitle = radio.streamUrl,
                icon = Icons.Rounded.Radio,
            )
        },
    ) {
        radio.homePageUrl?.takeIf { it.isNotBlank() }?.let { homePage ->
            ActionItem(
                icon = Icons.AutoMirrored.Rounded.OpenInNew,
                label = t("radios.table.homepage"),
                onClick = { runCatching { uriHandler.openUri(homePage) } },
            )
            ActionDivider()
        }
        ActionItem(
            icon = Icons.Rounded.Edit,
            label = t("radios.table.actions.edit"),
            onClick = { controller.show(Overlay.RadioForm(radio)) },
        )
        ActionItem(
            icon = Icons.Rounded.Delete,
            label = t("radios.table.actions.delete"),
            destructive = true,
            onClick = { controller.show(Overlay.DeleteRadio(radio)) },
        )
    }
}
