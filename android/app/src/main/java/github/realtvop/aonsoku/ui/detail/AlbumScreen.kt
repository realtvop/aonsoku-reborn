package github.realtvop.aonsoku.ui.detail

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
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
import github.realtvop.aonsoku.data.AlbumFilters
import github.realtvop.aonsoku.data.AlbumListRequest
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.Loadable
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.AlbumInfo
import github.realtvop.aonsoku.data.model.FeaturedArtist
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.QueueSource
import github.realtvop.aonsoku.ui.components.AlbumRowSection
import github.realtvop.aonsoku.ui.components.DiscHeader
import github.realtvop.aonsoku.ui.components.LoadableSource
import github.realtvop.aonsoku.ui.components.SongRow
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.humanDuration
import github.realtvop.aonsoku.ui.components.rememberNowPlaying
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.ArtistRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What an album page shows besides the album itself. */
data class AlbumExtras(
    val info: AlbumInfo? = null,
    val byArtist: List<Album> = emptyList(),
    val byGenre: List<Album> = emptyList(),
    /** The album without its tracks, for when the tracks cannot be loaded offline. */
    val summary: Album? = null,
)

class AlbumViewModel(private val graph: AppGraph, private val albumId: String) : ViewModel() {
    private val source = LoadableSource(viewModelScope) { graph.library.album(albumId) }
    private val _extras = MutableStateFlow(AlbumExtras())

    val album: StateFlow<Loadable<Album>> = source.state
    val extras: StateFlow<AlbumExtras> = _extras.asStateFlow()

    init {
        viewModelScope.launch { loadInfo() }
        viewModelScope.launch {
            source.state.collect { state ->
                if (state is Loadable.Failed && state.offline && _extras.value.summary == null) {
                    val summary = runCatching { graph.library.localAlbumSummary(albumId) }.getOrNull()
                    _extras.update { it.copy(summary = summary) }
                }
            }
        }
        viewModelScope.launch {
            // The related rows depend on the artist and genre of the album that is shown.
            combine(source.state, _extras) { state, extras ->
                val shown = (state as? Loadable.Ready)?.value ?: extras.summary
                shown?.let { it.artistId.orEmpty() to it.genre.orEmpty() }
            }.distinctUntilChanged().collectLatest { related ->
                if (related != null) loadRelated(related.first, related.second)
            }
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
            }
        }
    }

    private suspend fun loadInfo() {
        val info = runCatching { graph.library.albumInfo(albumId) }.getOrNull() ?: return
        _extras.update { it.copy(info = info) }
    }

    private suspend fun loadRelated(artistId: String, genre: String) = coroutineScope {
        val byArtist = async {
            if (artistId.isEmpty()) return@async emptyList()
            runCatching {
                graph.library.albums(
                    AlbumListRequest(filter = AlbumFilters.DISCOGRAPHY, artistId = artistId),
                    offset = 0,
                    limit = LibraryRepository.ALBUM_PAGE_SIZE,
                ).albums
            }.getOrDefault(emptyList())
        }
        val byGenre = async {
            if (genre.isEmpty()) return@async emptyList()
            runCatching { graph.library.genreAlbums(genre, RELATED_ALBUMS + 1) }
                .getOrDefault(emptyList())
        }
        val artistAlbums = relatedAlbums(byArtist.await(), albumId, newestFirst = true)
        val genreAlbums = relatedAlbums(byGenre.await(), albumId, newestFirst = false)
        _extras.update { it.copy(byArtist = artistAlbums, byGenre = genreAlbums) }
    }

    companion object {
        const val RELATED_ALBUMS = 16

        /** Other albums for a "more from" row: without [currentId], optionally newest first. */
        fun relatedAlbums(albums: List<Album>, currentId: String, newestFirst: Boolean): List<Album> {
            val others = albums.filter { it.id != currentId }
            val ordered = if (newestFirst) {
                // Albums without a year go last.
                others.sortedByDescending { it.year ?: Int.MIN_VALUE }
            } else {
                others
            }
            return ordered.take(RELATED_ALBUMS)
        }
    }
}

@Composable
fun AlbumScreen(route: AlbumRoute) {
    val model = graphViewModel { AlbumViewModel(it, route.id) }
    val loadable by model.album.collectAsStateWithLifecycle()
    val extras by model.extras.collectAsStateWithLifecycle()

    when (val current = loadable) {
        is Loadable.Ready -> AlbumContent(current.value, extras, tracksUnavailable = false)
        is Loadable.Failed -> {
            val summary = extras.summary
            if (current.offline && summary != null) {
                AlbumContent(summary, extras, tracksUnavailable = true)
            } else {
                DetailFailure(current)
            }
        }
        Loadable.Loading -> DetailLoading()
    }
}

@Composable
private fun AlbumContent(album: Album, extras: AlbumExtras, tracksUnavailable: Boolean) {
    val graph = LocalAppGraph.current
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current
    val strings = LocalStrings.current
    val nowPlaying = rememberNowPlaying()
    val header = remember(album.id) { DetailHeaderState() }

    val songs = album.song.orEmpty()
    val multipleDiscs = remember(songs) { songs.map { it.discNumber ?: 1 }.distinct().size > 1 }
    val artists = remember(album) { headerArtists(album) }
    val genre = album.genre?.takeIf { it.isNotEmpty() }
    val artistId = album.artistId?.takeIf { it.isNotEmpty() }

    val badges = buildList {
        album.year?.takeIf { it > 0 }?.let { add(HeaderBadge(it.toString())) }
        if (genre != null) {
            add(
                HeaderBadge(genre) {
                    navigator.open(AlbumsRoute(filter = AlbumFilters.BY_GENRE, genre = genre))
                },
            )
        }
    }
    val secondaryBadges = buildList {
        if (album.songCount > 0) add(HeaderBadge(plural("playlist.songCount", album.songCount)))
        if (album.duration > 0) {
            val duration = strings.humanDuration(album.duration)
            add(HeaderBadge(t("playlist.duration", "duration" to duration)))
        }
    }
    val moreFromArtist = t("album.more.listTitle")
    val discography = t("album.more.discography")
    val moreFromGenre = genre?.let { t("album.more.genreTitle", "genre" to it) }
    val seeMore = t("generic.seeMore")

    DetailPage(title = album.name, header = header) {
        item(key = "header", contentType = "header") {
            DetailHeader(
                state = header,
                type = t("album.headline"),
                title = album.name,
                art = CoverArt(album.coverArt ?: album.id),
                artists = artists,
                onArtist = { navigator.open(ArtistRoute(it.id)) },
                subtitle = album.artistLabel.takeIf { artists.isEmpty() },
                badges = badges,
                secondaryBadges = secondaryBadges,
            )
        }
        item(key = "actions", contentType = "actions") {
            DetailActions(
                state = header,
                name = album.name,
                enabled = songs.isNotEmpty(),
                onPlay = { graph.actions.playAlbum(album) },
                onShuffle = if (songs.size > 1) {
                    { graph.actions.playAlbum(album, shuffle = true) }
                } else {
                    null
                },
                onMore = { overlays.show(Overlay.AlbumMenu(album)) },
            )
        }

        val info = extras.info
        val notes = info?.notes
        if (!notes.isNullOrBlank()) {
            item(key = "info", contentType = "info") {
                InfoPanel(
                    name = album.name,
                    html = notes,
                    lastFmUrl = info?.lastFmUrl,
                    modifier = Modifier.padding(bottom = 16.dp),
                )
            }
        }

        if (tracksUnavailable) {
            item(key = "unavailable") {
                NoticeCard(
                    title = t("album.detail.songsUnavailableTitle"),
                    description = t("album.detail.songsUnavailable"),
                )
            }
        } else {
            itemsIndexed(
                items = songs,
                key = { index, song -> "song-$index-${song.id}" },
                contentType = { _, _ -> "song" },
            ) { index, song ->
                val disc = song.discNumber ?: 1
                val startsDisc = multipleDiscs &&
                    (index == 0 || (songs[index - 1].discNumber ?: 1) != disc)
                Column {
                    if (startsDisc) DiscHeader(disc)
                    SongRow(
                        song = song,
                        nowPlaying = nowPlaying,
                        onClick = {
                            graph.player.playSongs(
                                songs = songs,
                                index = index,
                                source = QueueSource.album(album.id),
                                sourceName = album.name,
                            )
                        },
                        onMore = { overlays.show(Overlay.SongMenu(song)) },
                    )
                }
            }
        }

        val comment = songs.firstOrNull()?.comment
        if (!comment.isNullOrBlank()) {
            item(key = "comment") {
                CommentCard(comment, modifier = Modifier.padding(top = 24.dp))
            }
        }

        val labels = album.recordLabels.orEmpty().filter { it.name.isNotBlank() }
        if (labels.isNotEmpty()) {
            item(key = "labels") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 20.dp, end = 20.dp, top = 24.dp),
                ) {
                    labels.take(MAX_RECORD_LABELS).forEach { label ->
                        Text(
                            text = listOfNotNull("℗", album.year?.toString(), label.name)
                                .joinToString(" "),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        if (extras.byArtist.isNotEmpty() && artistId != null) {
            item(key = "more-artist") {
                AlbumRowSection(
                    title = moreFromArtist,
                    albums = extras.byArtist,
                    onAlbum = { navigator.open(AlbumRoute(it.id)) },
                    onAlbumMenu = { overlays.show(Overlay.AlbumMenu(it)) },
                    moreLabel = discography,
                    onMore = {
                        navigator.open(AlbumsRoute(artistId = artistId, artistName = album.artist))
                    },
                )
            }
        }
        if (extras.byGenre.isNotEmpty() && genre != null && moreFromGenre != null) {
            item(key = "more-genre") {
                AlbumRowSection(
                    title = moreFromGenre,
                    albums = extras.byGenre,
                    onAlbum = { navigator.open(AlbumRoute(it.id)) },
                    onAlbumMenu = { overlays.show(Overlay.AlbumMenu(it)) },
                    moreLabel = seeMore,
                    onMore = {
                        navigator.open(AlbumsRoute(filter = AlbumFilters.BY_GENRE, genre = genre))
                    },
                )
            }
        }
        item(key = "end") { Spacer(Modifier.height(8.dp)) }
    }
}

/**
 * Artists linked above the artwork: every credited artist when there are
 * several, otherwise the album artist when it can be opened.
 */
internal fun headerArtists(album: Album): List<FeaturedArtist> {
    val credited = album.artists.orEmpty().filter { it.name.isNotBlank() }
    if (credited.size > 1) return credited
    val artistId = album.artistId.orEmpty()
    val name = album.artist.orEmpty()
    return if (artistId.isNotEmpty() && name.isNotEmpty()) {
        listOf(FeaturedArtist(artistId, name))
    } else {
        emptyList()
    }
}

private const val MAX_RECORD_LABELS = 3
