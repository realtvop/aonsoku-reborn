package github.realtvop.aonsoku.ui.detail

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.Loadable
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.ArtistInfo
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.AlbumRowSection
import github.realtvop.aonsoku.ui.components.ArtistRowSection
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.LoadableSource
import github.realtvop.aonsoku.ui.components.SectionHeader
import github.realtvop.aonsoku.ui.components.SongRow
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.rememberNowPlaying
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SongsRoute
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What an artist page shows besides the artist and their albums. */
data class ArtistExtras(
    val info: ArtistInfo? = null,
    val topSongs: List<Song> = emptyList(),
)

class ArtistViewModel(private val graph: AppGraph, private val artistId: String) : ViewModel() {
    private val source = LoadableSource(viewModelScope) { graph.library.artist(artistId) }
    private val _extras = MutableStateFlow(ArtistExtras())

    val artist: StateFlow<Loadable<Artist>> = source.state
    val extras: StateFlow<ArtistExtras> = _extras.asStateFlow()

    init {
        viewModelScope.launch { loadInfo() }
        viewModelScope.launch {
            // Top songs are looked up by artist name.
            source.state
                .map { (it as? Loadable.Ready)?.value?.name.orEmpty() }
                .distinctUntilChanged()
                .collectLatest { name -> loadTopSongs(name) }
        }
        viewModelScope.launch {
            graph.library.changes.collect { if (it == LibraryChange.Library) source.reload() }
        }
        viewModelScope.launch {
            // Coming back online fills in what could not be loaded before.
            graph.network.isOnline.drop(1).collect { online ->
                if (!online) return@collect
                if (source.value == null) source.reload()
                if (_extras.value.info == null) loadInfo()
                if (_extras.value.topSongs.isEmpty()) loadTopSongs(source.value?.name.orEmpty())
            }
        }
    }

    private suspend fun loadInfo() {
        val info = runSuspendCatching { graph.library.artistInfo(artistId) }.getOrNull() ?: return
        _extras.update { it.copy(info = info) }
    }

    private suspend fun loadTopSongs(artistName: String) {
        if (artistName.isEmpty()) return
        val songs = runSuspendCatching { graph.library.topSongs(artistName) }.getOrDefault(emptyList())
        if (songs.isNotEmpty()) _extras.update { it.copy(topSongs = songs.take(TOP_SONGS)) }
    }

    private companion object {
        const val TOP_SONGS = 10
    }
}

@Composable
fun ArtistScreen(route: ArtistRoute) {
    val model = graphViewModel { ArtistViewModel(it, route.id) }
    val loadable by model.artist.collectAsStateWithLifecycle()
    val extras by model.extras.collectAsStateWithLifecycle()

    when (val current = loadable) {
        is Loadable.Ready -> ArtistContent(current.value, extras)
        is Loadable.Failed -> DetailFailure(current)
        Loadable.Loading -> DetailLoading()
    }
}

@Composable
private fun ArtistContent(artist: Artist, extras: ArtistExtras) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current
    val nowPlaying = rememberNowPlaying()
    val header = remember(artist.id) { DetailHeaderState() }

    val albums = artist.album.orEmpty()
    val albumCount = maxOf(artist.albumCount, albums.size)
    val hasAlbums = albumCount > 0
    // Albums without a year go last.
    val recentAlbums = remember(albums) {
        albums.sortedByDescending { it.year ?: Int.MIN_VALUE }.take(RELATED_ITEMS)
    }
    val similarArtists = remember(extras.info) {
        extras.info?.similarArtist.orEmpty().filter { it.id.isNotEmpty() }.take(RELATED_ITEMS)
    }
    val topSongs = extras.topSongs
    val openAlbums = {
        navigator.open(AlbumsRoute(artistId = artist.id, artistName = artist.name))
    }
    val openSongs = {
        navigator.open(SongsRoute(artistId = artist.id, artistName = artist.name))
    }

    val badges = buildList {
        if (hasAlbums) {
            add(HeaderBadge(plural("artist.info.albumsCount", albumCount), openAlbums))
            if (artist.album != null) {
                val songCount = albums.sumOf { it.songCount }
                add(HeaderBadge(plural("playlist.songCount", songCount), openSongs))
            }
        }
    }
    val popular = t("artist.topSongs")
    val viewAll = t("generic.viewAll")
    val recentTitle = t("artist.recentAlbums")
    val discography = t("album.more.discography")
    val relatedTitle = t("artist.relatedArtists")

    DetailPage(title = artist.name, header = header) {
        item(key = "header", contentType = "header") {
            DetailHeader(
                state = header,
                type = t("artist.headline"),
                title = artist.name,
                art = CoverArt(artist.coverArt ?: artist.id),
                kind = CoverKind.Artist,
                badges = badges,
            )
        }
        item(key = "actions", contentType = "actions") {
            if (hasAlbums) {
                DetailActions(
                    state = header,
                    name = artist.name,
                    onPlay = { graph.actions.playArtist(artist.id, artist.name) },
                    onShuffle = { graph.actions.playArtist(artist.id, artist.name, shuffle = true) },
                    onMore = { overlays.show(Overlay.ArtistMenu(artist)) },
                )
            } else {
                DetailActions(state = header, name = artist.name)
            }
        }

        val info = extras.info
        val biography = info?.biography
        if (!biography.isNullOrBlank()) {
            item(key = "info", contentType = "info") {
                InfoPanel(
                    name = artist.name,
                    html = biography,
                    lastFmUrl = info.lastFmUrl,
                    musicBrainzUrl = info.musicBrainzId
                        ?.takeIf { it.isNotBlank() }
                        ?.let { "https://musicbrainz.org/artist/$it" },
                )
            }
        }

        if (topSongs.isNotEmpty()) {
            item(key = "top-title") {
                SectionHeader(title = popular, moreLabel = viewAll, onMore = openSongs)
            }
            itemsIndexed(
                items = topSongs,
                key = { index, song -> "top-$index-${song.id}" },
                contentType = { _, _ -> "song" },
            ) { index, song ->
                SongRow(
                    song = song,
                    nowPlaying = nowPlaying,
                    subtitle = song.album?.takeIf { it.isNotEmpty() } ?: song.artistLabel,
                    onClick = {
                        graph.player.playSongs(topSongs, index, sourceName = artist.name)
                    },
                    onMore = { overlays.show(Overlay.SongMenu(song)) },
                )
            }
        }

        if (recentAlbums.isNotEmpty()) {
            item(key = "albums") {
                AlbumRowSection(
                    title = recentTitle,
                    albums = recentAlbums,
                    onAlbum = { navigator.open(AlbumRoute(it.id)) },
                    onAlbumMenu = { overlays.show(Overlay.AlbumMenu(it)) },
                    moreLabel = discography,
                    onMore = openAlbums,
                )
            }
        }

        if (similarArtists.isNotEmpty()) {
            item(key = "related") {
                ArtistRowSection(
                    title = relatedTitle,
                    artists = similarArtists,
                    onArtist = { navigator.open(ArtistRoute(it.id)) },
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
        item(key = "end") { Spacer(Modifier.height(8.dp)) }
    }
}

private const val RELATED_ITEMS = 16
