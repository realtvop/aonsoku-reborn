package github.realtvop.aonsoku.actions

import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.i18n.Translations
import github.realtvop.aonsoku.player.PlayerController
import github.realtvop.aonsoku.player.QueueSource
import github.realtvop.aonsoku.settings.PinnedHomeItem
import github.realtvop.aonsoku.settings.SettingsRepository
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Library operations shared by menus, cards, and pages: resolving the songs
 * of an album, artist, or playlist and handing them to the player, playlist
 * and radio edits with their toasts, and pinning to the home page.
 */
class LibraryActions(
    private val scope: CoroutineScope,
    private val library: LibraryRepository,
    private val player: PlayerController,
    private val settings: SettingsRepository,
    private val toaster: Toaster,
    private val strings: () -> Translations,
) {
    // region Playback

    fun playAlbum(album: Album, shuffle: Boolean = false) = withSongs({ albumSongs(album) }) {
        player.playSongs(
            songs = it,
            index = if (shuffle) null else 0,
            shuffle = shuffle,
            source = QueueSource.album(album.id),
            sourceName = album.name,
        )
    }

    fun queueAlbum(album: Album, next: Boolean) = withSongs({ albumSongs(album) }) { enqueue(it, next) }

    /** Plays everything by an artist ("artist radio" in the web app). */
    fun playArtist(id: String, name: String, shuffle: Boolean = false) =
        withSongs({ library.artistSongs(id) }) {
            player.playSongs(
                songs = it,
                index = if (shuffle) null else 0,
                shuffle = shuffle,
                sourceName = name,
            )
        }

    fun queueArtist(artist: Artist, next: Boolean) =
        withSongs({ library.artistSongs(artist.id) }) { enqueue(it, next) }

    fun playPlaylist(playlist: Playlist, shuffle: Boolean = false) =
        withSongs({ playlistSongs(playlist) }) {
            player.playSongs(
                songs = it,
                index = if (shuffle) null else 0,
                shuffle = shuffle,
                source = QueueSource.playlist(playlist.id),
                sourceName = playlist.name,
            )
        }

    fun queuePlaylist(playlist: Playlist, next: Boolean) =
        withSongs({ playlistSongs(playlist) }) { enqueue(it, next) }

    fun enqueue(songs: List<Song>, next: Boolean) {
        if (next) player.addToQueueNext(songs) else player.addToQueueLast(songs)
    }

    private suspend fun albumSongs(album: Album): List<Song> =
        album.song?.takeIf { it.isNotEmpty() } ?: library.albumSongs(album.id)

    private suspend fun playlistSongs(playlist: Playlist): List<Song> =
        playlist.entry?.takeIf { it.isNotEmpty() } ?: library.playlistSongs(playlist.id)

    private fun withSongs(load: suspend () -> List<Song>, use: (List<Song>) -> Unit) {
        scope.launch {
            val songs = try {
                load()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                emptyList()
            }
            if (songs.isEmpty()) {
                toaster.error(strings().t("toast.server.error"))
            } else {
                use(songs)
            }
        }
    }

    // endregion

    // region Favorites

    fun setAlbumStarred(id: String, starred: Boolean) = mutate(
        failure = { strings().t("toast.server.error") },
    ) { library.setAlbumStarred(id, starred) }

    fun setArtistStarred(id: String, starred: Boolean) = mutate(
        failure = { strings().t("toast.server.error") },
    ) { library.setArtistStarred(id, starred) }

    // endregion

    // region Playlists

    fun addToPlaylist(playlistId: String, songIds: List<String>) = mutate(
        failure = { strings().t("toast.server.error") },
    ) { library.addToPlaylist(playlistId, songIds) }

    /** Creates a playlist named [name] that already contains [songIds]. */
    fun createPlaylistWith(name: String, songIds: List<String>) = mutate(
        failure = { strings().t("playlist.form.create.toast.error") },
    ) { library.createPlaylist(name = name, songIds = songIds) }

    fun addAlbumToPlaylist(album: Album, playlistId: String?) {
        scope.launch {
            val ids = runCatching { albumSongs(album) }.getOrDefault(emptyList()).map { it.id }
            if (ids.isEmpty()) {
                toaster.error(strings().t("toast.server.error"))
            } else if (playlistId == null) {
                createPlaylistWith(album.name, ids)
            } else {
                addToPlaylist(playlistId, ids)
            }
        }
    }

    fun createPlaylist(
        name: String,
        comment: String,
        isPublic: Boolean,
        onDone: () -> Unit = {},
        onFailed: () -> Unit = {},
    ) = mutate(
        success = { strings().t("playlist.form.create.toast.success") },
        failure = { strings().t("playlist.form.create.toast.error") },
        onDone = onDone,
        onFailed = onFailed,
    ) { library.createPlaylist(name, comment, isPublic) }

    fun updatePlaylist(
        id: String,
        name: String,
        comment: String,
        isPublic: Boolean,
        onDone: () -> Unit = {},
        onFailed: () -> Unit = {},
    ) = mutate(
        success = { strings().t("playlist.form.edit.toast.success") },
        failure = { strings().t("playlist.form.edit.toast.error") },
        onDone = onDone,
        onFailed = onFailed,
    ) { library.updatePlaylist(id, name, comment, isPublic) }

    fun deletePlaylist(id: String, onDone: () -> Unit = {}) = mutate(
        success = { strings().t("playlist.form.delete.toast.success") },
        failure = { strings().t("playlist.form.delete.toast.error") },
        onDone = onDone,
    ) {
        library.deletePlaylist(id)
        unpin(PinnedHomeItem(id, "playlist"))
    }

    fun removeFromPlaylist(id: String, indexes: List<Int>) = mutate(
        success = { strings().plural("playlist.form.removeSong.toast.success", indexes.size) },
        failure = { strings().plural("playlist.form.removeSong.toast.error", indexes.size) },
    ) { library.removeFromPlaylist(id, indexes) }

    // endregion

    // region Radios

    fun createRadio(
        name: String,
        streamUrl: String,
        homePageUrl: String,
        onDone: () -> Unit = {},
        onFailed: () -> Unit = {},
    ) = mutate(
        success = { strings().t("radios.form.create.toast.success") },
        failure = { strings().t("radios.form.create.toast.error") },
        onDone = onDone,
        onFailed = onFailed,
    ) { library.createRadio(name, streamUrl, homePageUrl) }

    fun updateRadio(radio: Radio, onDone: () -> Unit = {}, onFailed: () -> Unit = {}) = mutate(
        success = { strings().t("radios.form.edit.toast.success") },
        failure = { strings().t("radios.form.edit.toast.error") },
        onDone = onDone,
        onFailed = onFailed,
    ) { library.updateRadio(radio) }

    fun deleteRadio(id: String, onDone: () -> Unit = {}) = mutate(
        success = { strings().t("radios.form.delete.toast.success") },
        failure = { strings().t("radios.form.delete.toast.error") },
        onDone = onDone,
    ) { library.deleteRadio(id) }

    // endregion

    // region Pinned items

    fun isPinned(item: PinnedHomeItem): Boolean = item in settings.current.pinnedHome

    /** Pins [item] to the home page, or unpins it when it already is. */
    fun togglePin(item: PinnedHomeItem) {
        settings.update { current ->
            val pinned = current.pinnedHome
            current.copy(pinnedHome = if (item in pinned) pinned - item else listOf(item) + pinned)
        }
    }

    private fun unpin(item: PinnedHomeItem) {
        if (item !in settings.current.pinnedHome) return
        settings.update { it.copy(pinnedHome = it.pinnedHome - item) }
    }

    // endregion

    private fun mutate(
        success: (() -> String)? = null,
        failure: () -> String,
        onDone: () -> Unit = {},
        onFailed: () -> Unit = {},
        block: suspend () -> Unit,
    ) {
        scope.launch {
            try {
                block()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                toaster.error(failure())
                onFailed()
                return@launch
            }
            success?.let { toaster.success(it()) }
            onDone()
        }
    }
}
