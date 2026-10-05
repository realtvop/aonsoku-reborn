package github.realtvop.aonsoku.plugins.data

import android.content.Context
import android.util.Base64
import github.realtvop.aonsoku.plugins.bridge.AndroidCredentialStore
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicHttpClient
import github.realtvop.aonsoku.plugins.data.db.AonsokuDatabase
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
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

/**
 * Application-scoped owner of Android's local library and image cache.
 *
 * Capacitor creates and destroys plugin instances with the WebView. This
 * service deliberately has no Plugin/Activity/WebView reference, so a native
 * screen and a WebView adapter can use the same database and sync job at the
 * same time. There is no close operation: the process/application owns the
 * service for its lifetime.
 */
class LibraryService private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val database = AonsokuDatabase.getInstance(appContext)
    private val credentialStore = AndroidCredentialStore(appContext)
    private val httpClient = SubsonicHttpClient()
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
                credentialStore.retrieve()?.let(syncEngine::updateCredentials)
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
        credentialStore.retrieve()?.let(syncEngine::updateCredentials)
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
        if (ids.isEmpty()) emptyList() else database.songDao().getByIds(ids)
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

    suspend fun downloadCoverImage(coverArtId: String, size: String): CachedImageFile {
        val credentials = credentialStore.retrieve()
            ?: throw IllegalStateException("No stored credentials")
        return withContext(Dispatchers.IO) {
            val file = imageCache.downloadCoverImage(coverArtId, size, credentials)
            CachedImageFile(coverArtId, file, sizeBytes = file.length(), coverSize = size)
        }
    }

    suspend fun downloadAvatar(username: String, size: String): CachedImageFile {
        val credentials = credentialStore.retrieve()
            ?: throw IllegalStateException("No stored credentials")
        return withContext(Dispatchers.IO) {
            val file = imageCache.downloadAvatar(username, size, credentials)
            CachedImageFile(username, file, sizeBytes = file.length(), coverSize = size)
        }
    }

    fun storedCredentials(): ServerCredentials? = credentialStore.retrieve()

    companion object {
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
