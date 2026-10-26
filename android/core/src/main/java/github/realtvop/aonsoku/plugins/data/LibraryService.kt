package github.realtvop.aonsoku.plugins.data

import android.content.Context
import android.util.Base64
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.data.db.AonsokuDatabase
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity
import github.realtvop.aonsoku.plugins.data.db.entity.GenreEntity
import github.realtvop.aonsoku.plugins.data.db.entity.LyricsEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistDetailEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import github.realtvop.aonsoku.plugins.data.image.ImageCacheManager
import github.realtvop.aonsoku.plugins.data.sync.SyncEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

data class LibraryPage<T>(
    val items: List<T>,
    val total: Int,
    val hasMore: Boolean,
)

data class LibraryPagination(val limit: Int, val offset: Int) {
    val safeLimit: Int get() = limit.coerceAtLeast(0)
    val safeOffset: Int get() = offset.coerceAtLeast(0)
}

data class ArtistFilter(
    val search: String? = null,
    val starredOnly: Boolean = false,
    val sortBy: String? = null,
)

data class AlbumFilter(
    val search: String? = null,
    val artistId: String? = null,
    val genre: String? = null,
    val fromYear: Int? = null,
    val toYear: Int? = null,
    val starredOnly: Boolean = false,
    val sortBy: String? = null,
)

data class SongFilter(
    val search: String? = null,
    val albumId: String? = null,
    val artistId: String? = null,
    val genre: String? = null,
    val starredOnly: Boolean = false,
    val sortBy: String? = null,
)

data class LibrarySearchResult(
    val artists: List<ArtistEntity>,
    val albums: List<AlbumEntity>,
    val songs: List<SongEntity>,
)

data class LibrarySyncOptions(val mode: String = "full")

data class LibrarySyncState(
    val phase: String,
    val tier: String?,
    val isSyncing: Boolean,
    val progress: Int,
    val processedItems: Int,
    val totalItems: Int,
)

data class LibraryDataChange(val tables: List<String>, val tier: String)

data class LibraryInitialization(val needsMigration: Boolean)

data class CachedImageFile(
    val id: String,
    val file: File,
    val contentType: String? = null,
    val sizeBytes: Long = file.length(),
    val coverSize: String? = null,
)

data class LibraryCacheStats(
    val totalItems: Int,
    val totalSizeBytes: Long,
    val audioCount: Int,
    val coverCount: Int,
)

/** How many cover and avatar images are cached, and what they weigh. */
data class CoverCacheStats(val count: Int, val sizeBytes: Long)

/**
 * Application-scoped owner of Android's local library and image cache.
 *
 * The service deliberately holds no Activity reference, so every native
 * screen and the playback service share one database and one sync job. There
 * is no close operation: the process/application owns the service for its
 * lifetime.
 */
class LibraryService private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val database = AonsokuDatabase.getInstance(appContext)
    private val authenticationService = AuthenticationService.getInstance(appContext)
    private val httpClient = authenticationService.httpClient
    private val imageCache = ImageCacheManager(
        appContext.cacheDir,
        database.cacheMetaDao(),
    )
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val syncEngine = SyncEngine(
        httpClient = httpClient,
        artistDao = database.artistDao(),
        albumDao = database.albumDao(),
        songDao = database.songDao(),
        playlistDao = database.playlistDao(),
        genreDao = database.genreDao(),
        syncStateDao = database.syncStateDao(),
    )
    private val _syncState = MutableStateFlow(IDLE_SYNC_STATE)
    private val _dataChanges = MutableSharedFlow<LibraryDataChange>(
        extraBufferCapacity = 32,
    )
    private var initialized = false
    private var initializationJob: Job? = null

    val syncState: StateFlow<LibrarySyncState> = _syncState.asStateFlow()
    val dataChanges: SharedFlow<LibraryDataChange> = _dataChanges.asSharedFlow()

    init {
        syncEngine.onSyncStateChanged = { state ->
            _syncState.value = LibrarySyncState(
                phase = state["phase"] as? String ?: "idle",
                tier = state["tier"] as? String,
                isSyncing = state["isSyncing"] as? Boolean ?: false,
                progress = (state["progress"] as? Number)?.toInt() ?: 0,
                processedItems = (state["processedItems"] as? Number)?.toInt() ?: 0,
                totalItems = (state["totalItems"] as? Number)?.toInt() ?: 0,
            )
        }
        syncEngine.onDataChanged = { tables ->
            val tier = _syncState.value.tier ?: ""
            _dataChanges.tryEmit(LibraryDataChange(tables, tier))
        }
    }

    suspend fun initialize(): LibraryInitialization {
        initializationJob?.join()
        if (!initialized) {
            initializationJob = serviceScope.launch {
                authenticationService.getCredentials()?.let(syncEngine::updateCredentials)
                initialized = true
            }
            initializationJob?.join()
        }
        val hasFullSync = withContext(Dispatchers.IO) {
            database.syncStateDao().get("full-sync") != null
        }
        return LibraryInitialization(needsMigration = !hasFullSync)
    }

    suspend fun refreshCredentials() {
        initialize()
        authenticationService.getCredentials()?.let(syncEngine::updateCredentials)
    }

    fun syncAll(options: LibrarySyncOptions = LibrarySyncOptions()) {
        serviceScope.launch {
            refreshCredentials()
            syncEngine.syncAll(options.mode)
        }
    }

    fun syncIncremental() = syncAll(LibrarySyncOptions("incremental"))

    fun cancelSync() = syncEngine.cancel()

    suspend fun getArtists(
        pagination: LibraryPagination,
        filter: ArtistFilter,
    ): LibraryPage<ArtistEntity> = withContext(Dispatchers.IO) {
        val limit = pagination.safeLimit
        val offset = pagination.safeOffset
        val starred = if (filter.starredOnly) 1 else 0
        val items = database.artistDao().getFiltered(
            limit,
            offset,
            filter.search,
            starred,
            filter.sortBy,
        )
        val total = database.artistDao().countFiltered(filter.search, starred)
        LibraryPage(items, total, offset + limit < total)
    }

    suspend fun getArtist(id: String): ArtistEntity? = withContext(Dispatchers.IO) {
        database.artistDao().getById(id)
    }

    suspend fun getAlbums(
        pagination: LibraryPagination,
        filter: AlbumFilter,
    ): LibraryPage<AlbumEntity> = withContext(Dispatchers.IO) {
        val limit = pagination.safeLimit
        val offset = pagination.safeOffset
        val starred = if (filter.starredOnly) 1 else 0
        val items = database.albumDao().getFiltered(
            limit,
            offset,
            filter.search,
            filter.artistId,
            filter.genre,
            filter.fromYear,
            filter.toYear,
            starred,
            filter.sortBy,
        )
        val total = database.albumDao().countFiltered(
            filter.search,
            filter.artistId,
            filter.genre,
            filter.fromYear,
            filter.toYear,
            starred,
        )
        LibraryPage(items, total, offset + limit < total)
    }

    suspend fun getAlbum(id: String): Pair<AlbumEntity, List<SongEntity>>? =
        withContext(Dispatchers.IO) {
            database.albumDao().getById(id)?.let {
                it to database.albumDao().getSongsByAlbumId(id)
            }
        }

    suspend fun getSongs(
        pagination: LibraryPagination,
        filter: SongFilter,
    ): LibraryPage<SongEntity> = withContext(Dispatchers.IO) {
        val limit = pagination.safeLimit
        val offset = pagination.safeOffset
        val starred = if (filter.starredOnly) 1 else 0
        val items = database.songDao().getFiltered(
            limit,
            offset,
            filter.search,
            filter.albumId,
            filter.artistId,
            filter.genre,
            starred,
            filter.sortBy,
        )
        val total = database.songDao().countFiltered(
            filter.search,
            filter.albumId,
            filter.artistId,
            filter.genre,
            starred,
        )
        LibraryPage(items, total, offset + limit < total)
    }

    suspend fun getSongsByIds(ids: List<String>): List<SongEntity> = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) emptyList() else ids.distinct().chunked(SQL_VARIABLE_CHUNK).flatMap {
            database.songDao().getByIds(it)
        }
    }

    suspend fun getSong(id: String): SongEntity? = withContext(Dispatchers.IO) {
        database.songDao().getById(id)
    }

    suspend fun upsertSong(song: SongEntity) = withContext(Dispatchers.IO) {
        database.songDao().upsert(song)
        _dataChanges.tryEmit(LibraryDataChange(listOf("songs"), "remote"))
    }

    suspend fun toggleSongStarred(id: String): Boolean = withContext(Dispatchers.IO) {
        val song = database.songDao().getById(id) ?: return@withContext false
        val nextStarred = song.starredAt == null
        val timestamp = if (nextStarred) System.currentTimeMillis() / 1000 else null
        database.songDao().updateStarred(
            listOf(id),
            if (nextStarred) timestamp.toString() else null,
            timestamp,
        )
        _dataChanges.tryEmit(LibraryDataChange(listOf("songs"), "local"))
        nextStarred
    }

    suspend fun getPlaylists(pagination: LibraryPagination): LibraryPage<PlaylistEntity> =
        withContext(Dispatchers.IO) {
            val limit = pagination.safeLimit
            val offset = pagination.safeOffset
            val items = database.playlistDao().getAll(limit, offset)
            val total = database.playlistDao().count()
            LibraryPage(items, total, offset + limit < total)
        }

    suspend fun getPlaylist(id: String): PlaylistDetailEntity? = withContext(Dispatchers.IO) {
        database.playlistDao().getDetailById(id)
    }

    suspend fun getGenres(): List<GenreEntity> = withContext(Dispatchers.IO) {
        database.genreDao().getAll()
    }

    // region Typed queries for native screens

    suspend fun queryAlbums(query: AlbumQuery): LibraryPage<AlbumEntity> =
        withContext(Dispatchers.IO) {
            val items = database.albumDao().query(LibrarySql.albums(query))
            val total = database.albumDao().queryCount(LibrarySql.albumCount(query))
            LibraryPage(items, total, hasMore(query.limit, query.offset, total))
        }

    suspend fun querySongs(query: SongQuery): LibraryPage<SongEntity> =
        withContext(Dispatchers.IO) {
            val items = database.songDao().query(LibrarySql.songs(query))
            val total = database.songDao().queryCount(LibrarySql.songCount(query))
            LibraryPage(items, total, hasMore(query.limit, query.offset, total))
        }

    suspend fun queryArtists(query: ArtistQuery): LibraryPage<ArtistEntity> =
        withContext(Dispatchers.IO) {
            val items = database.artistDao().query(LibrarySql.artists(query))
            val total = database.artistDao().queryCount(LibrarySql.artistCount(query))
            LibraryPage(items, total, hasMore(query.limit, query.offset, total))
        }

    suspend fun getAlbumsByIds(ids: List<String>): List<AlbumEntity> =
        withContext(Dispatchers.IO) {
            if (ids.isEmpty()) emptyList() else ids.chunked(SQL_VARIABLE_CHUNK).flatMap {
                database.albumDao().getByIds(it)
            }
        }

    suspend fun countSongs(): Int = withContext(Dispatchers.IO) { database.songDao().count() }

    suspend fun countAlbums(): Int = withContext(Dispatchers.IO) { database.albumDao().count() }

    private fun hasMore(limit: Int?, offset: Int, total: Int): Boolean =
        limit != null && offset + limit < total

    // endregion

    // region Write-through from online browsing

    /** Keeps the local copy of an album and its tracks fresh after an online read. */
    suspend fun upsertAlbum(album: AlbumEntity, songs: List<SongEntity>) =
        withContext(Dispatchers.IO) {
            database.albumDao().upsert(album)
            if (songs.isNotEmpty()) database.songDao().bulkUpsert(songs)
        }

    suspend fun upsertAlbums(albums: List<AlbumEntity>) = withContext(Dispatchers.IO) {
        if (albums.isNotEmpty()) database.albumDao().bulkUpsert(albums)
    }

    suspend fun upsertSongs(songs: List<SongEntity>) = withContext(Dispatchers.IO) {
        if (songs.isNotEmpty()) database.songDao().bulkUpsert(songs)
    }

    suspend fun upsertPlaylists(playlists: List<PlaylistEntity>) = withContext(Dispatchers.IO) {
        if (playlists.isNotEmpty()) database.playlistDao().bulkUpsert(playlists)
    }

    /** Replaces the playlist summaries, dropping playlists deleted on the server. */
    suspend fun replacePlaylists(playlists: List<PlaylistEntity>) = withContext(Dispatchers.IO) {
        val dao = database.playlistDao()
        val keep = playlists.map { it.id }.toSet()
        val stale = dao.getAllDetailIds().filter { it !in keep }
        dao.deleteAll()
        if (playlists.isNotEmpty()) dao.bulkUpsert(playlists)
        if (stale.isNotEmpty()) dao.deleteDetails(stale)
        _dataChanges.tryEmit(LibraryDataChange(listOf("playlists"), "remote"))
    }

    suspend fun upsertPlaylistDetail(detail: PlaylistDetailEntity) = withContext(Dispatchers.IO) {
        val dao = database.playlistDao()
        dao.upsertDetail(detail)
        dao.upsert(
            PlaylistEntity(
                id = detail.id,
                name = detail.name,
                comment = detail.comment,
                songCount = detail.songCount,
                duration = detail.duration,
                isPublic = detail.isPublic,
                owner = detail.owner,
                created = detail.created,
                changed = detail.changed,
                coverArt = detail.coverArt,
                starred = detail.starred,
                starredAt = detail.starredAt,
            ),
        )
        _dataChanges.tryEmit(LibraryDataChange(listOf("playlists"), "remote"))
    }

    suspend fun deletePlaylist(id: String) = withContext(Dispatchers.IO) {
        database.playlistDao().deleteById(id)
        database.playlistDao().deleteDetailById(id)
        _dataChanges.tryEmit(LibraryDataChange(listOf("playlists"), "local"))
    }

    suspend fun setSongsStarred(ids: List<String>, starred: Boolean) =
        withContext(Dispatchers.IO) {
            if (ids.isEmpty()) return@withContext
            val now = System.currentTimeMillis()
            ids.chunked(SQL_VARIABLE_CHUNK).forEach { chunk ->
                database.songDao().updateStarred(
                    chunk,
                    if (starred) isoTimestamp(now) else null,
                    if (starred) now else null,
                )
            }
            _dataChanges.tryEmit(LibraryDataChange(listOf("songs", "favorites"), "local"))
        }

    suspend fun setAlbumStarred(id: String, starred: Boolean) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        database.albumDao().updateStarred(
            id,
            if (starred) isoTimestamp(now) else null,
            if (starred) now else null,
        )
        _dataChanges.tryEmit(LibraryDataChange(listOf("albums"), "local"))
    }

    suspend fun setArtistStarred(id: String, starred: Boolean) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        database.artistDao().updateStarred(
            id,
            if (starred) isoTimestamp(now) else null,
            if (starred) now else null,
        )
        _dataChanges.tryEmit(LibraryDataChange(listOf("artists"), "local"))
    }

    /** Drops the synced library (not the audio or cover files) and its sync markers. */
    suspend fun clearLibraryData() = withContext(Dispatchers.IO) {
        syncEngine.cancelAndJoin()
        database.songDao().deleteAll()
        database.albumDao().deleteAll()
        database.artistDao().deleteAll()
        database.playlistDao().deleteAll()
        database.playlistDao().deleteAllDetails()
        database.genreDao().deleteAll()
        database.lyricsDao().deleteAll()
        database.syncStateDao().deleteAll()
        _syncState.value = IDLE_SYNC_STATE
        _dataChanges.tryEmit(
            LibraryDataChange(
                listOf("songs", "albums", "artists", "playlists", "genres", "favorites"),
                "local",
            ),
        )
    }

    // endregion

    suspend fun getFavorites(
        pagination: LibraryPagination,
        type: String,
    ): LibraryPage<Any> = withContext(Dispatchers.IO) {
        val limit = pagination.safeLimit
        val offset = pagination.safeOffset
        when (type) {
            "artists" -> {
                val items = database.artistDao().getFiltered(limit, offset, null, 1, "starredAt")
                val total = database.artistDao().countFiltered(null, 1)
                LibraryPage(items.map { it as Any }, total, offset + limit < total)
            }
            "albums" -> {
                val items = database.albumDao().getFiltered(
                    limit,
                    offset,
                    null,
                    null,
                    null,
                    null,
                    null,
                    1,
                    "starredAt",
                )
                val total = database.albumDao().countFiltered(null, null, null, null, null, 1)
                LibraryPage(items.map { it as Any }, total, offset + limit < total)
            }
            else -> {
                val items = database.songDao().getFiltered(
                    limit,
                    offset,
                    null,
                    null,
                    null,
                    null,
                    1,
                    "starredAt",
                )
                val total = database.songDao().countFiltered(null, null, null, null, 1)
                LibraryPage(items.map { it as Any }, total, offset + limit < total)
            }
        }
    }

    suspend fun search(query: String, artistCount: Int, albumCount: Int, songCount: Int): LibrarySearchResult =
        withContext(Dispatchers.IO) {
            if (query.isBlank()) return@withContext LibrarySearchResult(emptyList(), emptyList(), emptyList())
            LibrarySearchResult(
                artists = database.artistDao().getFiltered(artistCount, 0, query, 0, "name"),
                albums = database.albumDao().getFiltered(albumCount, 0, query, null, null, null, null, 0, "name"),
                songs = database.songDao().getFiltered(songCount, 0, query, null, null, null, 0, "title"),
            )
        }

    suspend fun getLyrics(songId: String): LyricsEntity? = withContext(Dispatchers.IO) {
        database.lyricsDao().getBySongId(songId)?.also {
            database.lyricsDao().updateAccessTime(songId, System.currentTimeMillis())
        }
    }

    suspend fun storeLyrics(songId: String, content: String, synced: Boolean) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        database.lyricsDao().upsert(LyricsEntity(songId, content, synced, now, now))
    }

    suspend fun getCacheStats(): LibraryCacheStats = withContext(Dispatchers.IO) {
        LibraryCacheStats(
            totalItems = database.cacheMetaDao().totalItems(),
            totalSizeBytes = database.cacheMetaDao().totalSizeBytes(),
            audioCount = database.cacheMetaDao().audioCount(),
            coverCount = database.cacheMetaDao().coverCount(),
        )
    }

    suspend fun isDataAvailableOffline(): Long? = withContext(Dispatchers.IO) {
        database.syncStateDao().getLastSyncedAt("full-sync")
    }

    suspend fun storeCoverImage(
        coverArtId: String,
        dataBase64: String,
        contentType: String,
        coverSize: String,
    ): CachedImageFile = withContext(Dispatchers.IO) {
        val data = Base64.decode(dataBase64, Base64.DEFAULT)
        val file = imageCache.storeCoverImage(coverArtId, data, contentType, coverSize)
        CachedImageFile(coverArtId, file, contentType, data.size.toLong(), coverSize)
    }

    suspend fun resolveCoverImage(coverArtId: String): CachedImageFile? = withContext(Dispatchers.IO) {
        imageCache.resolveCoverImage(coverArtId)?.let {
            CachedImageFile(coverArtId, it, sizeBytes = it.length())
        }
    }

    suspend fun getCoverImageSize(coverArtId: String): Pair<Long, String?>? = withContext(Dispatchers.IO) {
        imageCache.getCoverImageSize(coverArtId)
    }

    suspend fun deleteCoverImage(coverArtId: String): Boolean = withContext(Dispatchers.IO) {
        imageCache.deleteCoverImage(coverArtId)
    }

    suspend fun clearCoverImages(): Int = withContext(Dispatchers.IO) {
        imageCache.clearCoverImages()
    }

    suspend fun getCoverCacheStats(): CoverCacheStats = withContext(Dispatchers.IO) {
        CoverCacheStats(
            count = database.cacheMetaDao().coverCount(),
            sizeBytes = database.cacheMetaDao().sizeByType(TYPE_COVER),
        )
    }

    /**
     * Deletes the images that were shown longest ago until the image cache
     * fits in [quotaBytes]; 0 means no limit. Returns how many went.
     */
    suspend fun trimCoverImages(quotaBytes: Long): Int = withContext(Dispatchers.IO) {
        if (quotaBytes <= 0) return@withContext 0
        val covers = database.cacheMetaDao().getByTypeOldestFirst(TYPE_COVER)
        var size = covers.sumOf { it.sizeBytes }
        var removed = 0
        for (cover in covers) {
            if (size <= quotaBytes) break
            imageCache.deleteCoverImage(cover.id)
            size -= cover.sizeBytes
            removed++
        }
        removed
    }

    /** Every row of the cache index: images, audio, and downloaded collections. */
    suspend fun getCacheEntries(): List<CacheMetaEntity> = withContext(Dispatchers.IO) {
        database.cacheMetaDao().getAll()
    }

    /**
     * The cover ids the synced library refers to, for fetching them ahead of
     * use. Artists are also shown by their own id. [songCovers] adds the
     * covers of single songs; [albumIds] adds the ids albums go by when song
     * rows show the album cover.
     */
    suspend fun getCoverArtIds(songCovers: Boolean, albumIds: Boolean): List<String> =
        withContext(Dispatchers.IO) {
            val ids = LinkedHashSet<String>()
            ids += database.artistDao().getCoverArtIds()
            ids += database.artistDao().getIds()
            ids += database.albumDao().getCoverArtIds()
            ids += database.playlistDao().getCoverArtIds()
            if (songCovers) ids += database.songDao().getCoverArtIds()
            if (albumIds) ids += database.albumDao().getIds()
            ids.filter { it.isNotEmpty() }
        }

    /**
     * What each cover id of the library belongs to: the name of the album,
     * artist, or playlist. An album names a cover before a playlist using it.
     */
    suspend fun getCoverNames(): Map<String, String> = withContext(Dispatchers.IO) {
        val names = HashMap<String, String>()
        val sources = listOf(
            database.albumDao().getCoverNames(),
            database.albumDao().getNames(),
            database.artistDao().getCoverNames(),
            database.artistDao().getNames(),
            database.playlistDao().getCoverNames(),
        )
        for (rows in sources) rows.forEach { names.putIfAbsent(it.id, it.name) }
        names
    }

    suspend fun clearLyrics() = withContext(Dispatchers.IO) { database.lyricsDao().deleteAll() }

    suspend fun getStarredSongIds(): List<String> = withContext(Dispatchers.IO) {
        database.songDao().getStarredSongIds()
    }

    suspend fun getStarredPlaylistIds(): List<String> = withContext(Dispatchers.IO) {
        database.playlistDao().getStarredIds()
    }

    /** Which of [ids] are songs of the synced library. */
    suspend fun getExistingSongIds(ids: Collection<String>): Set<String> = withContext(Dispatchers.IO) {
        ids.chunked(SQL_VARIABLE_CHUNK).flatMapTo(HashSet()) { database.songDao().getExistingIds(it) }
    }

    suspend fun downloadCoverImage(coverArtId: String, size: String): CachedImageFile {
        val credentials = authenticationService.getCredentials()
            ?: throw IllegalStateException("No stored credentials")
        return withContext(Dispatchers.IO) {
            val file = imageCache.downloadCoverImage(coverArtId, size, credentials)
            CachedImageFile(coverArtId, file, sizeBytes = file.length(), coverSize = size)
        }
    }

    suspend fun downloadAvatar(username: String, size: String): CachedImageFile {
        val credentials = authenticationService.getCredentials()
            ?: throw IllegalStateException("No stored credentials")
        return withContext(Dispatchers.IO) {
            val file = imageCache.downloadAvatar(username, size, credentials)
            CachedImageFile(username, file, sizeBytes = file.length(), coverSize = size)
        }
    }

    fun storedCredentials(): ServerCredentials? = authenticationService.getCredentials()

    private fun isoTimestamp(epochMillis: Long): String =
        java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }.format(java.util.Date(epochMillis))

    companion object {
        /** SQLite binds at most 999 variables per statement on older devices. */
        private const val SQL_VARIABLE_CHUNK = 500
        private const val TYPE_COVER = "cover"

        private val IDLE_SYNC_STATE = LibrarySyncState(
            phase = "idle",
            tier = null,
            isSyncing = false,
            progress = 0,
            processedItems = 0,
            totalItems = 0,
        )
        @Volatile
        private var instance: LibraryService? = null

        fun getInstance(context: Context): LibraryService = instance ?: synchronized(this) {
            instance ?: LibraryService(context.applicationContext).also { instance = it }
        }
    }
}
