package github.realtvop.aonsoku.plugins.data

import android.content.Context
import android.util.Base64
import androidx.room.withTransaction
import org.json.JSONArray
import java.time.Instant
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
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
        if (ids.isEmpty()) emptyList() else database.songDao().getByIds(ids)
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

    /** Repeated query keys retain exact song order and duplicate playlist entries. */
    suspend fun serverRequest(endpoint: String, params: List<Pair<String, String>> = emptyList()): JSONObject {
        val credentials = authenticationService.getCredentials() ?: error("Sign in first")
        return authenticationService.request(credentials, NativeLibraryCodec.requestPath(endpoint, params)).data
    }

    suspend fun setStarred(id: String, kind: String, starred: Boolean) {
        val key = when (kind) { "album" -> "albumId"; "artist" -> "artistId"; else -> "id" }
        serverRequest(if (starred) "star" else "unstar", listOf(key to id))
        val timestamp = if (starred) System.currentTimeMillis() else null
        val date = timestamp?.let { Instant.ofEpochMilli(it).toString() }
        withContext(Dispatchers.IO) {
            when (kind) {
                "album" -> database.albumDao().getById(id)?.let { database.albumDao().upsert(it.copy(starred = date, starredAt = timestamp)) }
                "artist" -> database.artistDao().getById(id)?.let { database.artistDao().upsert(it.copy(starred = date, starredAt = timestamp)) }
                else -> database.songDao().getById(id)?.let { database.songDao().upsert(it.copy(starred = date, starredAt = timestamp)) }
            }
            _dataChanges.emit(LibraryDataChange(listOf("songs", "albums", "artists"), "mutation"))
        }
    }

    suspend fun rateSong(id: String, rating: Int) {
        require(rating in 0..5)
        serverRequest("setRating", listOf("id" to id, "rating" to rating.toString()))
    }

    suspend fun refreshPlaylist(id: String): PlaylistDetailEntity {
        val item = serverRequest("getPlaylist", listOf("id" to id)).getJSONObject("playlist")
        return persistPlaylist(item)
    }

    private suspend fun persistPlaylist(item: JSONObject): PlaylistDetailEntity = withContext(Dispatchers.IO) {
        val detail = PlaylistDetailEntity(
            id = item.getString("id"), name = item.getString("name"),
            comment = item.optString("comment", null), songCount = item.optInt("songCount"),
            duration = item.optInt("duration"), isPublic = item.optBoolean("public"),
            owner = item.optString("owner", null), created = item.optString("created", null),
            changed = item.optString("changed", null), coverArt = item.optString("coverArt", null),
            entriesJson = item.optJSONArray("entry")?.toString() ?: "[]",
        )
        val entries = JSONArray(detail.entriesJson)
        database.withTransaction {
            database.playlistDao().upsertDetail(detail)
            database.playlistDao().upsert(PlaylistEntity(
                detail.id, detail.name, detail.comment, detail.songCount, detail.duration,
                detail.isPublic, detail.owner, detail.created, detail.changed, detail.coverArt,
            ))
            database.songDao().bulkUpsert((0 until entries.length()).mapNotNull { NativeLibraryCodec.parseSong(entries.optJSONObject(it)) })
        }
        _dataChanges.emit(LibraryDataChange(listOf("playlists", "songs"), "mutation"))
        detail
    }

    suspend fun createPlaylist(name: String, comment: String, public: Boolean, songIds: List<String>): PlaylistDetailEntity {
        require(name.isNotBlank())
        val response = serverRequest("createPlaylist", listOf("name" to name) + songIds.map { "songId" to it })
        val detail = persistPlaylist(response.getJSONObject("playlist"))
        return updatePlaylist(detail.id, name, comment, public)
    }

    suspend fun updatePlaylist(id: String, name: String? = null, comment: String? = null, public: Boolean? = null, add: List<String> = emptyList(), removeIndices: List<Int> = emptyList()): PlaylistDetailEntity {
        val detail = getPlaylist(id)
        require(detail?.owner == null || detail.owner == storedCredentials()?.username) { "Only the playlist owner can edit it" }
        val params = mutableListOf("playlistId" to id)
        name?.let { require(it.isNotBlank()); params += "name" to it }
        comment?.let { params += "comment" to it }
        public?.let { params += "public" to it.toString() }
        params += add.map { "songIdToAdd" to it }
        params += removeIndices.sortedDescending().map { "songIndexToRemove" to it.toString() }
        serverRequest("updatePlaylist", params)
        return refreshPlaylist(id)
    }

    suspend fun replacePlaylistSongs(id: String, songIds: List<String>) {
        val detail = getPlaylist(id)
        require(detail?.owner == null || detail.owner == storedCredentials()?.username) { "Only the playlist owner can edit it" }
        // createPlaylist with playlistId replaces entries atomically on Subsonic.
        serverRequest("createPlaylist", listOf("playlistId" to id) + songIds.map { "songId" to it })
        refreshPlaylist(id)
    }

    suspend fun deletePlaylist(id: String) {
        val detail = getPlaylist(id)
        require(detail?.owner == null || detail.owner == storedCredentials()?.username) { "Only the playlist owner can delete it" }
        serverRequest("deletePlaylist", listOf("id" to id))
        withContext(Dispatchers.IO) {
            database.withTransaction { database.playlistDao().deleteById(id); database.playlistDao().deleteDetails(listOf(id)) }
        }
        _dataChanges.emit(LibraryDataChange(listOf("playlists"), "mutation"))
    }

    suspend fun getRadios(): List<NativeRadio> {
        val response = serverRequest("getInternetRadioStations").optJSONObject("internetRadioStations")?.optJSONArray("internetRadioStation") ?: JSONArray()
        return (0 until response.length()).map { NativeRadio.from(response.getJSONObject(it)) }
    }
    suspend fun saveRadio(radio: NativeRadio) {
        require(radio.name.length >= 3) { "Name must contain at least 3 characters" }
        require(java.net.URI(radio.streamUrl).scheme in listOf("http", "https")) { "Enter an http or https stream URL" }
        serverRequest(if (radio.id.isBlank()) "createInternetRadioStation" else "updateInternetRadioStation", listOf("name" to radio.name, "streamUrl" to radio.streamUrl, "homePageUrl" to radio.homePageUrl) + if (radio.id.isBlank()) emptyList() else listOf("id" to radio.id))
    }
    suspend fun deleteRadio(id: String) { serverRequest("deleteInternetRadioStation", listOf("id" to id)) }

    suspend fun getArtistInfo(id: String): JSONObject = serverRequest("getArtistInfo2", listOf("id" to id)).optJSONObject("artistInfo2") ?: JSONObject()
    suspend fun getTopSongs(artist: String): List<SongEntity> {
        val rows = serverRequest("getTopSongs", listOf("artist" to artist, "count" to "50")).optJSONObject("topSongs")?.optJSONArray("song") ?: JSONArray()
        val songs = (0 until rows.length()).mapNotNull { NativeLibraryCodec.parseSong(rows.optJSONObject(it)) }
        withContext(Dispatchers.IO) { database.songDao().bulkUpsert(songs) }
        return songs
    }

    fun storedCredentials(): ServerCredentials? = authenticationService.getCredentials()

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


data class NativeRadio(val id: String, val name: String, val streamUrl: String, val homePageUrl: String = "") {
    companion object {
        fun from(item: JSONObject) = NativeRadio(item.optString("id"), item.optString("name"), item.optString("streamUrl"), item.optString("homePageUrl"))
    }
}
