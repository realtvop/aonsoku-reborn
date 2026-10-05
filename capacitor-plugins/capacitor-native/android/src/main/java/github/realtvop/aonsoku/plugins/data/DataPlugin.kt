package github.realtvop.aonsoku.plugins.data

import android.os.Handler
import android.os.Looper
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import github.realtvop.aonsoku.plugins.data.db.toJSArray
import github.realtvop.aonsoku.plugins.data.db.toJSObject
import github.realtvop.aonsoku.plugins.debug.NativeLogger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@CapacitorPlugin(name = "AonsokuNativeData")
class DataPlugin : Plugin() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var library: LibraryService? = null
    private var syncStateJob: Job? = null
    private var dataChangesJob: Job? = null
    private var ready = false
    private val emitter = EventEmitter { event, data -> notifyListeners(event, data) }

    private fun service(): LibraryService {
        library?.let { return it }
        return LibraryService.getInstance(context).also {
            library = it
            subscribeToService(it)
        }
    }

    private fun subscribeToService(service: LibraryService) {
        if (syncStateJob == null) {
            syncStateJob = scope.launch {
                service.syncState.collect { state ->
                    emitter.emitSyncStateChanged(
                        mapOf(
                            "phase" to state.phase,
                            "tier" to state.tier,
                            "isSyncing" to state.isSyncing,
                            "progress" to state.progress,
                            "processedItems" to state.processedItems,
                            "totalItems" to state.totalItems,
                        ),
                    )
                }
            }
        }
        if (dataChangesJob == null) {
            dataChangesJob = scope.launch {
                service.dataChanges.collect { change ->
                    emitter.emitDataChanged(change.tables, change.tier)
                }
            }
        }
    }

    override fun handleOnDestroy() {
        syncStateJob?.cancel()
        dataChangesJob?.cancel()
        scope.cancel()
        // LibraryService is application scoped. Destroying this adapter must
        // not stop a sync job or close Room for native screens.
        super.handleOnDestroy()
    }

    @PluginMethod
    fun initialize(call: PluginCall) = launch(call) {
        val service = service()
        val result = service.initialize()
        service.refreshCredentials()
        if (result.needsMigration) service.syncAll() else service.syncIncremental()
        JSObject().apply {
            put("ready", true)
            put("needsMigration", result.needsMigration)
        }
    }

    @PluginMethod
    fun importBulk(call: PluginCall) = resolve(call)

    @PluginMethod
    fun syncAll(call: PluginCall) {
        service().syncAll()
        resolve(call)
    }

    @PluginMethod
    fun syncIncremental(call: PluginCall) {
        service().syncIncremental()
        resolve(call)
    }

    @PluginMethod
    fun cancelSync(call: PluginCall) {
        service().cancelSync()
        resolve(call)
    }

    @PluginMethod
    fun getSyncState(call: PluginCall) {
        val state = service().syncState.value
        resolve(
            call,
            JSObject().apply {
                put("phase", state.phase)
                put("tier", state.tier ?: JSONObject.NULL)
                put("isSyncing", state.isSyncing)
                put("progress", state.progress)
                put("processedItems", state.processedItems)
                put("totalItems", state.totalItems)
            },
        )
    }

    @PluginMethod
    fun getArtists(call: PluginCall) = launch(call) {
        service().getArtists(
            pagination(call),
            ArtistFilter(
                search = call.getString("search"),
                starredOnly = call.getBoolean("starredOnly") == true,
                sortBy = call.getString("sortBy"),
            ),
        ).toJS { it.toJSObject() }
    }

    @PluginMethod
    fun getArtist(call: PluginCall) {
        val id = call.getString("id") ?: return reject(call, "no id")
        launch(call) { service().getArtist(id)?.toJSObject() ?: JSObject() }
    }

    @PluginMethod
    fun getAlbums(call: PluginCall) = launch(call) {
        service().getAlbums(
            pagination(call),
            AlbumFilter(
                search = call.getString("search"),
                artistId = call.getString("artistId"),
                genre = call.getString("genre"),
                fromYear = call.getInt("fromYear"),
                toYear = call.getInt("toYear"),
                starredOnly = call.getBoolean("starredOnly") == true,
                sortBy = call.getString("sortBy"),
            ),
        ).toJS { it.toJSObject() }
    }

    @PluginMethod
    fun getAlbum(call: PluginCall) {
        val id = call.getString("id") ?: return reject(call, "no id")
        launch(call) {
            service().getAlbum(id)?.let { (album, songs) ->
                album.toJSObject().apply {
                    put("song", songs.map { it.toJSObject() }.toJSArray())
                }
            } ?: JSObject()
        }
    }

    @PluginMethod
    fun getSongs(call: PluginCall) = launch(call) {
        service().getSongs(
            pagination(call),
            SongFilter(
                search = call.getString("search"),
                albumId = call.getString("albumId"),
                artistId = call.getString("artistId"),
                genre = call.getString("genre"),
                starredOnly = call.getBoolean("starredOnly") == true,
                sortBy = call.getString("sortBy"),
            ),
        ).toJS { it.toJSObject() }
    }

    @PluginMethod
    fun getPlaylists(call: PluginCall) = launch(call) {
        service().getPlaylists(pagination(call)).toJS { it.toJSObject() }
    }

    @PluginMethod
    fun getPlaylist(call: PluginCall) {
        val id = call.getString("id") ?: return reject(call, "no id")
        launch(call) { service().getPlaylist(id)?.toJSObject() ?: JSObject() }
    }

    @PluginMethod
    fun getGenres(call: PluginCall) = launch(call) {
        JSObject().apply {
            put("items", service().getGenres().map { it.toJSObject() }.toJSArray())
        }
    }

    @PluginMethod
    fun getFavorites(call: PluginCall) = launch(call) {
        service().getFavorites(
            pagination(call),
            call.getString("type") ?: "songs",
        ).toJS {
            when (it) {
                is ArtistEntity -> it.toJSObject()
                is AlbumEntity -> it.toJSObject()
                is SongEntity -> it.toJSObject()
                else -> JSObject()
            }
        }
    }

    @PluginMethod
    fun search(call: PluginCall) = launch(call) {
        val result = service().search(
            query = call.getString("query") ?: "",
            artistCount = call.getInt("artistCount") ?: 20,
            albumCount = call.getInt("albumCount") ?: 20,
            songCount = call.getInt("songCount") ?: 20,
        )
        JSObject().apply {
            put("artists", result.artists.map { it.toJSObject() }.toJSArray())
            put("albums", result.albums.map { it.toJSObject() }.toJSArray())
            put("songs", result.songs.map { it.toJSObject() }.toJSArray())
        }
    }

    @PluginMethod
    fun getLyrics(call: PluginCall) {
        val songId = call.getString("songId") ?: return reject(call, "no songId")
        launch(call) { service().getLyrics(songId)?.toJSObject() ?: JSObject() }
    }

    @PluginMethod
    fun storeLyrics(call: PluginCall) {
        val songId = call.getString("songId")
        val content = call.getString("content")
        if (songId == null || content == null) return reject(call, "missing params")
        launch(call) {
            service().storeLyrics(songId, content, call.getBoolean("synced") ?: false)
            null
        }
    }

    @PluginMethod
    fun getCacheStats(call: PluginCall) = launch(call) {
        service().getCacheStats().let {
            JSObject().apply {
                put("totalItems", it.totalItems)
                put("totalSizeBytes", it.totalSizeBytes)
                put("audioCount", it.audioCount)
                put("coverCount", it.coverCount)
            }
        }
    }

    @PluginMethod
    fun isDataAvailableOffline(call: PluginCall) = launch(call) {
        val lastSyncedAt = service().isDataAvailableOffline()
        JSObject().apply {
            put("available", lastSyncedAt != null)
            put("lastSyncedAt", lastSyncedAt ?: JSONObject.NULL)
        }
    }

    @PluginMethod
    fun storeCoverImage(call: PluginCall) {
        val id = call.getString("coverArtId") ?: return reject(call, "no id")
        val data = call.getString("dataBase64") ?: return reject(call, "no data")
        launch(call) {
            service().storeCoverImage(
                id,
                data,
                call.getString("contentType") ?: "image/jpeg",
                call.getString("coverSize") ?: "700",
            ).toJSObject()
        }
    }

    @PluginMethod
    fun resolveCoverImage(call: PluginCall) {
        val id = call.getString("coverArtId") ?: return reject(call, "no id")
        launch(call) { service().resolveCoverImage(id).toJSResult() }
    }

    @PluginMethod
    fun getCoverImageSize(call: PluginCall) {
        val id = call.getString("coverArtId") ?: return reject(call, "no id")
        launch(call) {
            service().getCoverImageSize(id).let { result ->
                JSObject().apply {
                    put("sizeBytes", result?.first ?: JSONObject.NULL)
                    put("coverSize", result?.second ?: JSONObject.NULL)
                }
            }
        }
    }

    @PluginMethod
    fun deleteCoverImage(call: PluginCall) {
        val id = call.getString("coverArtId") ?: return reject(call, "no id")
        launch(call) { JSObject().put("deleted", service().deleteCoverImage(id)) }
    }

    @PluginMethod
    fun clearCoverImages(call: PluginCall) = launch(call) {
        JSObject().put("deletedCount", service().clearCoverImages())
    }

    @PluginMethod
    fun downloadCoverImage(call: PluginCall) {
        val id = call.getString("coverArtId") ?: return reject(call, "no id")
        launch(call) {
            service().downloadCoverImage(id, call.getString("size") ?: "700").toJSObject()
        }
    }

    @PluginMethod
    fun downloadAvatar(call: PluginCall) {
        val username = call.getString("username") ?: return reject(call, "no username")
        launch(call) {
            service().downloadAvatar(username, call.getString("size") ?: "150").toJSObject()
        }
    }

    private fun pagination(call: PluginCall) = LibraryPagination(
        limit = call.getInt("limit") ?: 100,
        offset = call.getInt("offset") ?: 0,
    )

    private fun <T> LibraryPage<T>.toJS(convert: (T) -> JSObject): JSObject = JSObject().apply {
        put("items", items.map(convert).toJSArray())
        put("total", total)
        put("hasMore", hasMore)
    }

    private fun CachedImageFile.toJSObject(): JSObject = JSObject().apply {
        put("file", JSObject().apply {
            put("coverArtId", id)
            put("uri", file.toURI().toString())
            contentType?.let { put("contentType", it) }
            put("sizeBytes", sizeBytes)
            coverSize?.let { put("coverSize", it) }
        })
    }

    private fun CachedImageFile?.toJSResult(): JSObject = JSObject().apply {
        put("file", this@toJSResult?.let { image ->
            JSObject().apply {
                put("coverArtId", image.id)
                put("uri", image.file.toURI().toString())
                put("sizeBytes", image.sizeBytes)
                image.contentType?.let { put("contentType", it) }
                image.coverSize?.let { put("coverSize", it) }
            }
        } ?: JSONObject.NULL)
    }

    private fun <T> launch(call: PluginCall, block: suspend () -> T?) {
        if (!ready) {
            ready = true
            service()
        }
        scope.launch {
            try {
                val result = block()
                if (result is JSObject) resolve(call, result) else resolve(call)
            } catch (error: Throwable) {
                NativeLogger.error(
                    "Native library operation failed: ${error.message}",
                    "data-plugin",
                )
                reject(call, error.message ?: "error")
            }
        }
    }

    private fun resolve(call: PluginCall) {
        mainHandler.post { call.resolve() }
    }

    private fun resolve(call: PluginCall, data: JSObject) {
        mainHandler.post { call.resolve(data) }
    }

    private fun reject(call: PluginCall, message: String) {
        mainHandler.post { call.reject(message) }
    }
}
