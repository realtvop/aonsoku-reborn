package github.realtvop.aonsoku.data

import github.realtvop.aonsoku.data.api.ApiException
import github.realtvop.aonsoku.data.api.SubsonicApi
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.AlbumInfo
import github.realtvop.aonsoku.data.model.AlbumPage
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.ArtistInfo
import github.realtvop.aonsoku.data.model.Genre
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.data.model.SearchResult
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.plugins.data.AlbumQuery
import github.realtvop.aonsoku.plugins.data.AlbumSort
import github.realtvop.aonsoku.plugins.data.ArtistQuery
import github.realtvop.aonsoku.plugins.data.LibraryPagination
import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.plugins.data.SongQuery
import github.realtvop.aonsoku.plugins.data.SongSort
import github.realtvop.aonsoku.settings.PinnedHomeItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.Calendar
import kotlin.random.Random

/** Result of a read that may show cached data before the server answers. */
sealed interface Loadable<out T> {
    data object Loading : Loadable<Nothing>

    /** [refreshing] is true while a newer copy is still being fetched. */
    data class Ready<T>(val value: T, val refreshing: Boolean = false) : Loadable<T>

    data class Failed(val notFound: Boolean = false, val offline: Boolean = false) :
        Loadable<Nothing>
}

/** What changed, so screens can decide whether to reload. */
enum class LibraryChange { Favorites, Playlists, Radios, Library }

enum class HomeSection(val apiType: String) {
    RecentlyPlayed("recent"),
    MostPlayed("frequent"),
    RecentlyAdded("newest"),
    Explore("random"),
}

/** Album list arguments; [filter] uses the Subsonic/web filter identifiers. */
data class AlbumListRequest(
    val filter: String = AlbumFilters.RECENTLY_ADDED,
    val yearFilter: String = AlbumFilters.YEAR_OLDEST,
    val genre: String? = null,
    val artistId: String? = null,
    val query: String? = null,
    /** Keeps the "random" order stable while paging. */
    val randomSeed: Long = 0,
)

object AlbumFilters {
    const val BY_ARTIST = "alphabeticalByArtist"
    const val BY_GENRE = "byGenre"
    const val STARRED = "starred"
    const val MOST_PLAYED = "frequent"
    const val BY_NAME = "alphabeticalByName"
    const val RANDOM = "random"
    const val RECENTLY_ADDED = "newest"
    const val RECENTLY_PLAYED = "recent"
    const val BY_YEAR = "byYear"
    const val DISCOGRAPHY = "artistDiscography"
    const val SEARCH = "search"

    const val YEAR_OLDEST = "oldest"
    const val YEAR_NEWEST = "newest"

    /** Filters offered in the album filter sheet, in display order. */
    val selectable: List<Pair<String, String>> = listOf(
        BY_ARTIST to "album.list.filter.artist",
        STARRED to "album.list.filter.favorites",
        MOST_PLAYED to "album.list.filter.mostPlayed",
        BY_NAME to "album.list.filter.name",
        RANDOM to "album.list.filter.random",
        RECENTLY_ADDED to "album.list.filter.recentlyAdded",
        RECENTLY_PLAYED to "album.list.filter.recentlyPlayed",
        BY_YEAR to "album.list.filter.releaseYear",
    )
}

enum class SongOrder(val key: String, val labelKey: String) {
    LastAdded("lastAdded", "songs.sort.lastAdded"),
    Artist("artist", "songs.sort.artist"),
    Title("title", "songs.sort.title"),
    Album("album", "songs.sort.album"),
    ;

    companion object {
        fun fromKey(key: String): SongOrder = entries.firstOrNull { it.key == key } ?: LastAdded
    }
}

data class SongListRequest(
    val query: String = "",
    val artistId: String? = null,
    val order: SongOrder = SongOrder.LastAdded,
    val ascending: Boolean = false,
)

data class SongPage(val songs: List<Song>, val total: Int, val hasMore: Boolean)

sealed interface PinnedEntry {
    val playedAt: Long

    data class PinnedAlbum(val album: Album, override val playedAt: Long) : PinnedEntry

    data class PinnedPlaylist(val playlist: Playlist, override val playedAt: Long) : PinnedEntry
}

/**
 * Single read/write entry point for library data. Lists come from the local
 * Room library whenever it has been synced and fall back to the server
 * otherwise; detail pages show the local copy first and refresh it from the
 * server when online. Everything read online is written through to Room so it
 * stays available offline.
 */
class LibraryRepository(
    private val api: SubsonicApi,
    private val library: LibraryService,
    private val network: NetworkMonitor,
) {
    private val _changes = MutableSharedFlow<LibraryChange>(extraBufferCapacity = 16)
    private val _starredOverrides = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    private val requestLimit = Semaphore(ALBUM_FETCH_CONCURRENCY)

    val changes: SharedFlow<LibraryChange> = _changes.asSharedFlow()

    /**
     * Star state changed during this session, keyed by song, album, or artist
     * id. Lists keep the objects they loaded, so UI that shows a star reads
     * this first.
     */
    val starredOverrides: StateFlow<Map<String, Boolean>> = _starredOverrides.asStateFlow()

    fun isStarred(id: String, loaded: Boolean): Boolean = _starredOverrides.value[id] ?: loaded

    private val online: Boolean get() = network.online

    fun notifyChanged(change: LibraryChange) {
        _changes.tryEmit(change)
    }

    // region Home

    suspend fun homeAlbums(section: HomeSection): List<Album> {
        if (online) {
            remote { api.getAlbumList(section.apiType, size = HOME_SECTION_SIZE).albums }
                ?.let { albums ->
                    library.upsertAlbums(albums.map { it.toEntity() })
                    return albums
                }
        }
        val sort = when (section) {
            HomeSection.RecentlyPlayed -> AlbumSort.RecentlyPlayed
            HomeSection.MostPlayed -> AlbumSort.MostPlayed
            HomeSection.RecentlyAdded -> AlbumSort.RecentlyAdded
            HomeSection.Explore -> AlbumSort.Random
        }
        return library.queryAlbums(AlbumQuery(sort = sort, limit = HOME_SECTION_SIZE))
            .items.map { it.toModel() }
    }

    suspend fun carouselAlbums(): List<Album> {
        if (online) {
            remote { api.getAlbumList(AlbumFilters.RANDOM, size = CAROUSEL_SIZE).albums }
                ?.let { return it }
        }
        return library.queryAlbums(AlbumQuery(sort = AlbumSort.Random, limit = CAROUSEL_SIZE))
            .items.map { it.toModel() }
    }

    /** Pinned albums and playlists, most recently played first. */
    suspend fun pinnedItems(pinned: List<PinnedHomeItem>): List<PinnedEntry> {
        val items = pinned.distinctBy { it.type to it.id }
        if (items.isEmpty()) return emptyList()
        val localAlbums = library.getAlbumsByIds(items.filter { it.type == "album" }.map { it.id })
            .associateBy { it.id }
        val localPlaylists = library.getPlaylists(LibraryPagination(MAX_ROWS, 0))
            .items.associateBy { it.id }

        return coroutineScope {
            items.map { item ->
                async {
                    if (item.type == "album") {
                        val album = localAlbums[item.id]?.toModel()
                            ?: if (online) remote { api.getAlbum(item.id) } else null
                        album?.let {
                            PinnedEntry.PinnedAlbum(
                                album = it.copy(song = null),
                                playedAt = parseIsoTimestamp(it.played) ?: 0,
                            )
                        }
                    } else {
                        val detail = library.getPlaylist(item.id)?.toModel()
                        val playlist = detail ?: localPlaylists[item.id]?.toModel()
                            ?: if (online) remote { api.getPlaylist(item.id) } else null
                        playlist?.let {
                            val lastPlayed = it.entry.orEmpty()
                                .maxOfOrNull { song -> parseIsoTimestamp(song.played) ?: 0 }
                                ?.takeIf { time -> time > 0 }
                                ?: parseIsoTimestamp(it.changed)
                                ?: parseIsoTimestamp(it.created)
                                ?: 0
                            PinnedEntry.PinnedPlaylist(it.copy(entry = null), lastPlayed)
                        }
                    }
                }
            }.awaitAll().filterNotNull()
        }.sortedWith(
            compareByDescending<PinnedEntry> { it.playedAt }.thenBy {
                when (it) {
                    is PinnedEntry.PinnedAlbum -> it.album.name.lowercase()
                    is PinnedEntry.PinnedPlaylist -> it.playlist.name.lowercase()
                }
            },
        )
    }

    // endregion

    // region Lists

    suspend fun artists(): List<Artist> {
        val local = library.queryArtists(ArtistQuery()).items
        if (local.isNotEmpty()) return local.map { it.toModel() }
        if (!online) return emptyList()
        return remote { api.getArtists() }.orEmpty().distinctBy { it.id }
    }

    suspend fun albums(request: AlbumListRequest, offset: Int, limit: Int): AlbumPage {
        val hasLocal = library.countAlbums() > 0
        val serverOrdered = request.filter == AlbumFilters.RECENTLY_PLAYED ||
            request.filter == AlbumFilters.MOST_PLAYED
        if (online && (!hasLocal || (serverOrdered && request.artistId == null))) {
            remote { remoteAlbums(request, offset, limit) }?.let { return it }
        }
        return localAlbums(request, offset, limit)
    }

    private suspend fun localAlbums(request: AlbumListRequest, offset: Int, limit: Int): AlbumPage {
        if (request.artistId != null) {
            val page = library.queryAlbums(
                AlbumQuery(sort = AlbumSort.YearNewest, artistId = request.artistId),
            )
            return AlbumPage(page.items.map { it.toModel() }, page.total)
        }
        if (request.filter == AlbumFilters.RANDOM) {
            // SQL cannot page a random order consistently; shuffle once with a
            // stable seed and page in memory.
            val all = library.queryAlbums(AlbumQuery(sort = AlbumSort.Name)).items
            val shuffled = all.shuffled(Random(request.randomSeed))
            return AlbumPage(
                shuffled.drop(offset).take(limit).map { it.toModel() },
                shuffled.size,
            )
        }
        val query = when (request.filter) {
            AlbumFilters.BY_ARTIST -> AlbumQuery(sort = AlbumSort.Artist)
            AlbumFilters.BY_GENRE -> AlbumQuery(sort = AlbumSort.Name, genre = request.genre.orEmpty())
            AlbumFilters.STARRED -> AlbumQuery(sort = AlbumSort.Starred)
            AlbumFilters.MOST_PLAYED -> AlbumQuery(sort = AlbumSort.MostPlayed)
            AlbumFilters.BY_NAME -> AlbumQuery(sort = AlbumSort.Name)
            AlbumFilters.RECENTLY_PLAYED -> AlbumQuery(sort = AlbumSort.RecentlyPlayed)
            AlbumFilters.BY_YEAR -> AlbumQuery(
                sort = if (request.yearFilter == AlbumFilters.YEAR_NEWEST) {
                    AlbumSort.YearNewest
                } else {
                    AlbumSort.YearOldest
                },
            )
            AlbumFilters.SEARCH -> AlbumQuery(sort = AlbumSort.Name, search = request.query)
            else -> AlbumQuery(sort = AlbumSort.RecentlyAdded)
        }
        val page = library.queryAlbums(query.copy(limit = limit, offset = offset))
        return AlbumPage(page.items.map { it.toModel() }, page.total)
    }

    private suspend fun remoteAlbums(request: AlbumListRequest, offset: Int, limit: Int): AlbumPage {
        request.artistId?.let { artistId ->
            val albums = api.getArtist(artistId)?.album.orEmpty()
            return AlbumPage(if (offset == 0) albums else emptyList(), albums.size)
        }
        if (request.filter == AlbumFilters.SEARCH) {
            val query = request.query.orEmpty()
            if (query.isBlank()) return AlbumPage(emptyList(), 0)
            val albums = api.search(
                query = query,
                artistCount = 0,
                songCount = 0,
                albumCount = limit,
                albumOffset = offset,
            ).album
            return AlbumPage(albums, offset + albums.size + if (albums.size >= limit) 1 else 0)
        }
        val currentYear = Calendar.getInstance().get(Calendar.YEAR)
        val (fromYear, toYear) = when {
            request.filter != AlbumFilters.BY_YEAR -> null to null
            request.yearFilter == AlbumFilters.YEAR_NEWEST -> currentYear to 1
            else -> 1 to currentYear
        }
        val page = api.getAlbumList(
            type = request.filter,
            size = limit,
            offset = offset,
            fromYear = fromYear,
            toYear = toYear,
            genre = request.genre?.takeIf { request.filter == AlbumFilters.BY_GENRE },
        )
        val total = when {
            page.total > 0 -> page.total
            page.albums.size >= limit -> offset + page.albums.size + 1
            else -> offset + page.albums.size
        }
        return AlbumPage(page.albums, total)
    }

    suspend fun songs(request: SongListRequest, offset: Int, limit: Int): SongPage {
        val hasLocal = library.countSongs() > 0
        if (!hasLocal && online) {
            remote { remoteSongs(request, offset, limit) }?.let { return it }
        }
        val sort = when (request.order) {
            SongOrder.LastAdded -> SongSort.LastAdded
            SongOrder.Artist -> SongSort.Artist
            SongOrder.Title -> SongSort.Title
            SongOrder.Album -> SongSort.Album
        }
        val page = library.querySongs(
            SongQuery(
                sort = sort,
                ascending = request.ascending,
                search = request.query.takeIf { it.isNotBlank() && request.artistId == null },
                artistId = request.artistId,
                limit = if (request.artistId != null) null else limit,
                offset = if (request.artistId != null) 0 else offset,
            ),
        )
        return SongPage(page.items.map { it.toModel() }, page.total, page.hasMore)
    }

    private suspend fun remoteSongs(request: SongListRequest, offset: Int, limit: Int): SongPage {
        request.artistId?.let { artistId ->
            val songs = sortSongs(remoteArtistSongs(artistId), request.order, request.ascending)
            return SongPage(if (offset == 0) songs else emptyList(), songs.size, false)
        }
        val songs = api.search(
            query = request.query,
            artistCount = 0,
            albumCount = 0,
            songCount = limit,
            songOffset = offset,
        ).song
        return SongPage(
            songs = sortSongs(songs, request.order, request.ascending),
            total = offset + songs.size,
            hasMore = songs.size >= limit,
        )
    }

    private fun sortSongs(songs: List<Song>, order: SongOrder, ascending: Boolean): List<Song> {
        val comparator: Comparator<Song> = when (order) {
            SongOrder.Artist -> compareBy { it.artist.orEmpty().lowercase() }
            SongOrder.Title -> compareBy { it.title.lowercase() }
            SongOrder.Album -> compareBy { it.album.orEmpty().lowercase() }
            SongOrder.LastAdded -> compareBy { parseIsoTimestamp(it.created) ?: 0 }
        }
        return songs.sortedWith(if (ascending) comparator else comparator.reversed())
    }

    suspend fun totalSongCount(): Int = library.countSongs()

    /** All songs of an artist, for "play artist" and the artist song list. */
    suspend fun artistSongs(artistId: String): List<Song> {
        val local = library.querySongs(SongQuery(sort = SongSort.LastAdded, artistId = artistId))
        if (local.items.isNotEmpty()) return local.items.map { it.toModel() }
        if (!online) return emptyList()
        return remote { remoteArtistSongs(artistId) }.orEmpty()
            .sortedByDescending { parseIsoTimestamp(it.created) ?: 0 }
    }

    private suspend fun remoteArtistSongs(artistId: String): List<Song> = coroutineScope {
        val albums = api.getArtist(artistId)?.album.orEmpty()
        albums.map { album ->
            async { requestLimit.withPermit { fetchAlbum(album.id)?.song.orEmpty() } }
        }.awaitAll().flatten()
    }

    fun favoriteSongs(): Flow<Loadable<List<Song>>> = cachedThenFresh(
        cached = {
            library.querySongs(SongQuery(sort = SongSort.Starred))
                .items.map { it.toModel() }
                .takeIf { it.isNotEmpty() || library.countSongs() > 0 }
        },
        fresh = {
            val starred = api.getStarred().song
            syncStarredSongs(starred)
            starred
        },
        acceptEmptyOffline = true,
        empty = emptyList(),
    )

    private suspend fun syncStarredSongs(starred: List<Song>) {
        val ids = starred.map { it.id }.toSet()
        val stale = library.querySongs(SongQuery(sort = SongSort.Starred)).items
            .map { it.id }
            .filterNot { it in ids }
        if (stale.isNotEmpty()) library.setSongsStarred(stale, false)
        library.upsertSongs(starred.map { it.toEntity() })
    }

    fun playlists(): Flow<Loadable<List<Playlist>>> = cachedThenFresh(
        cached = {
            library.getPlaylists(LibraryPagination(MAX_ROWS, 0)).items
                .map { it.toModel() }
                .takeIf { it.isNotEmpty() }
        },
        fresh = {
            val playlists = api.getPlaylists().distinctBy { it.id }
            library.replacePlaylists(playlists.map { it.toEntity() })
            playlists
        },
        acceptEmptyOffline = true,
        empty = emptyList(),
    )

    suspend fun playlistsNow(): List<Playlist> {
        if (online) {
            remote { api.getPlaylists() }?.distinctBy { it.id }?.let { playlists ->
                library.replacePlaylists(playlists.map { it.toEntity() })
                return playlists
            }
        }
        return library.getPlaylists(LibraryPagination(MAX_ROWS, 0)).items.map { it.toModel() }
    }

    suspend fun radios(): List<Radio> {
        if (!online) return emptyList()
        return api.getRadios().distinctBy { it.id }
    }

    suspend fun genres(): List<Genre> {
        val local = library.getGenres()
        if (local.isNotEmpty()) return local.map { it.toModel() }
        if (!online) return emptyList()
        return remote { api.getGenres() }.orEmpty().sortedBy { it.value.lowercase() }
    }

    suspend fun search(query: String, count: Int): SearchResult {
        val local = library.search(query, count, count, count)
        val result = SearchResult(
            artist = local.artists.map { it.toModel() },
            album = local.albums.map { it.toModel() },
            song = local.songs.map { it.toModel() },
        )
        if (!result.isEmpty || !online) return result
        val found = remote {
            api.search(query, artistCount = count, albumCount = count, songCount = count)
        } ?: return result
        return found.copy(
            artist = found.artist.distinctBy { it.id },
            album = found.album.distinctBy { it.id },
            song = found.song.distinctBy { it.id },
        )
    }

    // endregion

    // region Details

    fun album(id: String): Flow<Loadable<Album>> = cachedThenFresh(
        cached = { localAlbum(id)?.takeIf { !it.song.isNullOrEmpty() } },
        fresh = { fetchAlbum(id) },
    )

    /** An album known locally only as a summary (no tracks synced yet). */
    suspend fun localAlbumSummary(id: String): Album? = localAlbum(id)

    private suspend fun localAlbum(id: String): Album? {
        val (album, songs) = library.getAlbum(id) ?: return null
        return album.toModel().copy(song = songs.map { it.toModel() })
    }

    private suspend fun fetchAlbum(id: String): Album? {
        val album = api.getAlbum(id) ?: return null
        library.upsertAlbum(album.toEntity(), album.song.orEmpty().map { it.toEntity() })
        return album
    }

    /** Tracks of an album for playback, preferring the local copy. */
    suspend fun albumSongs(id: String): List<Song> {
        val local = localAlbum(id)
        val localSongs = local?.song.orEmpty()
        if (localSongs.isNotEmpty() && (!online || localSongs.size >= local!!.songCount)) {
            return localSongs
        }
        if (!online) return localSongs
        return remote { fetchAlbum(id)?.song }.orEmpty().ifEmpty { localSongs }
    }

    /** Full album (tracks, record labels) from the server when online, else the local copy. */
    suspend fun albumDetails(id: String): Album? {
        if (online) remote { fetchAlbum(id) }?.let { return it }
        return localAlbum(id)
    }

    suspend fun albumInfo(id: String): AlbumInfo? =
        if (online) remote { api.getAlbumInfo(id) } else null

    fun artist(id: String): Flow<Loadable<Artist>> = cachedThenFresh(
        cached = {
            library.getArtist(id)?.toModel()?.let { artist ->
                val albums = library.queryAlbums(
                    AlbumQuery(sort = AlbumSort.YearNewest, artistId = id),
                ).items.map { it.toModel() }
                artist.copy(album = albums)
            }
        },
        fresh = {
            api.getArtist(id)?.also { artist ->
                library.upsertAlbums(artist.album.orEmpty().map { it.toEntity() })
            }
        },
    )

    suspend fun artistInfo(id: String): ArtistInfo? =
        if (online) remote { api.getArtistInfo(id) } else null

    suspend fun topSongs(artistName: String): List<Song> =
        if (online) remote { api.getTopSongs(artistName) }.orEmpty() else emptyList()

    /** Other albums of the same genre, for the "More from genre" row. */
    suspend fun genreAlbums(genre: String, limit: Int = HOME_SECTION_SIZE): List<Album> {
        val local = library.queryAlbums(
            AlbumQuery(sort = AlbumSort.Random, genre = genre, limit = limit),
        ).items
        if (local.isNotEmpty()) return local.map { it.toModel() }
        if (!online) return emptyList()
        return remote {
            api.getAlbumList(AlbumFilters.BY_GENRE, size = limit, genre = genre).albums
        }.orEmpty()
    }

    fun playlist(id: String): Flow<Loadable<Playlist>> = cachedThenFresh(
        cached = { library.getPlaylist(id)?.toModel() },
        fresh = { fetchPlaylist(id) },
    )

    private suspend fun fetchPlaylist(id: String): Playlist? {
        val playlist = api.getPlaylist(id)
        if (playlist == null) {
            library.deletePlaylist(id)
            return null
        }
        library.upsertPlaylistDetail(playlist.toDetailEntity())
        return playlist
    }

    suspend fun playlistSongs(id: String): List<Song> {
        if (online) {
            remote { fetchPlaylist(id)?.entry }?.let { return it }
        }
        return library.getPlaylist(id)?.toModel()?.entry.orEmpty()
    }

    suspend fun song(id: String): Song? {
        if (online) {
            remote { api.getSong(id) }?.let { song ->
                library.upsertSong(song.toEntity())
                return song
            }
        }
        return library.getSong(id)?.toModel()
    }

    suspend fun localSong(id: String): Song? = library.getSong(id)?.toModel()

    /**
     * Makes sure [songs] are in the local library, so they are listed while
     * offline. A song that is there already stays as it is: the copy at hand
     * may know less about it (one rebuilt from the queue, for example).
     */
    suspend fun remember(songs: List<Song>) {
        if (songs.isEmpty()) return
        val known = library.getExistingSongIds(songs.map { it.id })
        val unknown = songs.filter { it.id !in known }
        if (unknown.isNotEmpty()) library.upsertSongs(unknown.map { it.toEntity() })
    }

    // endregion

    // region Mutations

    /** Stars or unstars a song. Throws when the server cannot be reached. */
    suspend fun setSongStarred(song: Song, starred: Boolean) {
        if (library.getSong(song.id) == null) {
            library.upsertSong(song.toEntity())
        }
        library.setSongsStarred(listOf(song.id), starred)
        _starredOverrides.update { it + (song.id to starred) }
        try {
            if (starred) api.star(song.id) else api.unstar(song.id)
        } catch (error: Exception) {
            library.setSongsStarred(listOf(song.id), !starred)
            _starredOverrides.update { it + (song.id to !starred) }
            throw error
        }
        _changes.tryEmit(LibraryChange.Favorites)
    }

    suspend fun setAlbumStarred(id: String, starred: Boolean) {
        setStarred(id, starred) { library.setAlbumStarred(id, starred) }
    }

    suspend fun setArtistStarred(id: String, starred: Boolean) {
        setStarred(id, starred) { library.setArtistStarred(id, starred) }
    }

    /** Optimistic star change for albums and artists; undone when the server call fails. */
    private suspend fun setStarred(id: String, starred: Boolean, persist: suspend () -> Unit) {
        val previous = _starredOverrides.value[id]
        _starredOverrides.update { it + (id to starred) }
        try {
            if (starred) api.star(id) else api.unstar(id)
        } catch (error: Exception) {
            _starredOverrides.update { if (previous == null) it - id else it + (id to previous) }
            throw error
        }
        persist()
        _changes.tryEmit(LibraryChange.Favorites)
    }

    suspend fun createPlaylist(
        name: String,
        comment: String = "",
        isPublic: Boolean = false,
        songIds: List<String> = emptyList(),
    ): Playlist? {
        val created = api.createPlaylist(name) ?: return null
        api.updatePlaylist(
            playlistId = created.id,
            comment = comment.takeIf { it.isNotEmpty() },
            isPublic = isPublic.takeIf { it },
            songIdsToAdd = songIds,
        )
        val playlist = fetchPlaylist(created.id) ?: created
        _changes.tryEmit(LibraryChange.Playlists)
        return playlist
    }

    suspend fun updatePlaylist(id: String, name: String, comment: String, isPublic: Boolean) {
        api.updatePlaylist(id, name = name, comment = comment, isPublic = isPublic)
        fetchPlaylist(id)
        _changes.tryEmit(LibraryChange.Playlists)
    }

    suspend fun addToPlaylist(id: String, songIds: List<String>) {
        if (songIds.isEmpty()) return
        api.updatePlaylist(id, songIdsToAdd = songIds)
        fetchPlaylist(id)
        _changes.tryEmit(LibraryChange.Playlists)
    }

    suspend fun removeFromPlaylist(id: String, indexes: List<Int>) {
        if (indexes.isEmpty()) return
        api.updatePlaylist(id, songIndexesToRemove = indexes)
        fetchPlaylist(id)
        _changes.tryEmit(LibraryChange.Playlists)
    }

    suspend fun deletePlaylist(id: String) {
        api.deletePlaylist(id)
        library.deletePlaylist(id)
        _changes.tryEmit(LibraryChange.Playlists)
    }

    suspend fun createRadio(name: String, streamUrl: String, homePageUrl: String) {
        api.createRadio(name, streamUrl, homePageUrl)
        _changes.tryEmit(LibraryChange.Radios)
    }

    suspend fun updateRadio(radio: Radio) {
        api.updateRadio(radio)
        _changes.tryEmit(LibraryChange.Radios)
    }

    suspend fun deleteRadio(id: String) {
        api.deleteRadio(id)
        _changes.tryEmit(LibraryChange.Radios)
    }

    // endregion

    /**
     * Emits the local copy first (when there is one) and then the server
     * copy. Offline, the local copy is final; a missing local copy fails.
     */
    private fun <T : Any> cachedThenFresh(
        cached: suspend () -> T?,
        fresh: suspend () -> T?,
        acceptEmptyOffline: Boolean = false,
        empty: T? = null,
    ): Flow<Loadable<T>> = flow {
        emit(Loadable.Loading)
        val local = try {
            cached()
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            null
        }
        if (!online) {
            emit(
                when {
                    local != null -> Loadable.Ready(local)
                    acceptEmptyOffline && empty != null -> Loadable.Ready(empty)
                    else -> Loadable.Failed(offline = true)
                },
            )
            return@flow
        }
        if (local != null) emit(Loadable.Ready(local, refreshing = true))
        try {
            val remote = fresh()
            emit(
                when {
                    remote != null -> Loadable.Ready(remote)
                    else -> Loadable.Failed(notFound = true)
                },
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            emit(
                when {
                    local != null -> Loadable.Ready(local)
                    acceptEmptyOffline && empty != null && error is ApiException.NetworkUnreachable ->
                        Loadable.Ready(empty)
                    else -> Loadable.Failed(offline = error is ApiException.NetworkUnreachable)
                },
            )
        }
    }

    /** Runs a server read and returns null when it fails for any non-cancel reason. */
    private suspend fun <T> remote(block: suspend () -> T): T? = try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        null
    }

    companion object {
        const val HOME_SECTION_SIZE = 16
        const val CAROUSEL_SIZE = 10
        const val ALBUM_PAGE_SIZE = 128
        const val SONG_PAGE_SIZE = 100
        private const val MAX_ROWS = 100_000
        private const val ALBUM_FETCH_CONCURRENCY = 6
    }
}
