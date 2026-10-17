package github.realtvop.aonsoku.ui.overlays

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.devices.DevicesSheet

/** Menus, pickers, and dialogs that can be opened from anywhere in the app. */
sealed interface Overlay {
    /**
     * Options of a song. [playlistId] and [playlistIndex] are set on a
     * playlist page and add "remove from playlist"; [queueRemove] is set for
     * queue entries and adds "remove from queue".
     */
    data class SongMenu(
        val song: Song,
        val playlistId: String? = null,
        val playlistIndex: Int? = null,
        val queueRemove: (() -> Unit)? = null,
    ) : Overlay

    data class AlbumMenu(val album: Album) : Overlay

    data class ArtistMenu(val artist: Artist) : Overlay

    data class PlaylistMenu(
        val playlist: Playlist,
        val showPlay: Boolean = false,
        val onDeleted: (() -> Unit)? = null,
    ) : Overlay

    data class RadioMenu(val radio: Radio) : Overlay

    /** Playlist picker for [songIds], or for all tracks of [album]. */
    data class AddToPlaylist(
        val suggestedName: String,
        val songIds: List<String> = emptyList(),
        val album: Album? = null,
    ) : Overlay

    /** Create a playlist, or edit [playlist] when it is given. */
    data class PlaylistForm(val playlist: Playlist? = null) : Overlay

    data class DeletePlaylist(val playlist: Playlist, val onDeleted: (() -> Unit)? = null) : Overlay

    data class RemoveFromPlaylist(val playlistId: String, val indexes: List<Int>) : Overlay

    data class RadioForm(val radio: Radio? = null) : Overlay

    data class DeleteRadio(val radio: Radio) : Overlay

    data class SongInfo(val songId: String) : Overlay

    /** Options of the song that is playing, opened from the full-screen player. */
    data object CurrentSongMenu : Overlay

    data object SleepTimer : Overlay

    /** How strongly the artwork tints the full-screen player. */
    data object PlayerColors : Overlay

    /** The devices of the cross-device account: control them, or continue their playback here. */
    data object Devices : Overlay

    /** Full-screen view of an artwork. */
    data class Artwork(
        val art: CoverArt,
        val kind: CoverKind = CoverKind.Album,
        val title: String? = null,
    ) : Overlay
}

@Stable
class OverlayController {
    var current: Overlay? by mutableStateOf(null)
        private set

    fun show(overlay: Overlay) {
        current = overlay
    }

    fun dismiss() {
        current = null
    }
}

val LocalOverlays = staticCompositionLocalOf<OverlayController> {
    error("OverlayController is not provided")
}

/** Renders the overlay that is currently requested, if any. */
@Composable
fun OverlayHost(controller: OverlayController) {
    val overlay = controller.current ?: return
    key(overlay) {
        when (overlay) {
            is Overlay.SongMenu -> SongMenuSheet(overlay, controller)
            is Overlay.AlbumMenu -> AlbumMenuSheet(overlay, controller)
            is Overlay.ArtistMenu -> ArtistMenuSheet(overlay, controller)
            is Overlay.PlaylistMenu -> PlaylistMenuSheet(overlay, controller)
            is Overlay.RadioMenu -> RadioMenuSheet(overlay, controller)
            is Overlay.AddToPlaylist -> AddToPlaylistSheet(overlay, controller)
            is Overlay.PlaylistForm -> PlaylistFormDialog(overlay, controller)
            is Overlay.DeletePlaylist -> DeletePlaylistDialog(overlay, controller)
            is Overlay.RemoveFromPlaylist -> RemoveFromPlaylistDialog(overlay, controller)
            is Overlay.RadioForm -> RadioFormDialog(overlay, controller)
            is Overlay.DeleteRadio -> DeleteRadioDialog(overlay, controller)
            is Overlay.SongInfo -> SongInfoSheet(overlay, controller)
            Overlay.CurrentSongMenu -> CurrentSongMenuSheet(controller)
            Overlay.SleepTimer -> SleepTimerSheet(controller)
            Overlay.PlayerColors -> PlayerColorsSheet(controller)
            Overlay.Devices -> DevicesSheet(controller)
            is Overlay.Artwork -> ArtworkViewer(overlay, controller)
        }
    }
}
