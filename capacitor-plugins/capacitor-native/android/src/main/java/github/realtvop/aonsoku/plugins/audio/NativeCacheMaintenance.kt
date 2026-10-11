package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.data.*
import github.realtvop.aonsoku.plugins.network.NativeNetworkMonitor
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject

/** Derives smart downloads and cover sync from native metadata/preferences. */
@OptIn(FlowPreview::class)
class NativeCacheMaintenance(context: Context, private val downloads: NativeDownloadManager) {
    private val services = AppServices.getInstance(context)
    private val network = NativeNetworkMonitor.getInstance(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private var previousSettings = ""
    init {
        scope.launch { services.library.dataChanges.debounce(1500).collect { maintain() } }
        scope.launch { services.preferences.changes.collect { val settings = it.preferences["cache_store"].orEmpty() + it.preferences["player_store"].orEmpty().substringBefore("\"queue\""); if (settings != previousSettings) { previousSettings = settings; maintain() } } }
        scope.launch { network.online.collect { if (it) { downloads.retryPending(); maintain() } } }
    }
    private suspend fun maintain() = mutex.withLock {
        val prefs = services.preferences.getAllPreferences()
        val settings = runCatching { JSONObject(prefs["cache_store"] ?: "{}").getJSONObject("state").getJSONObject("settings") }.getOrDefault(JSONObject())
        services.library.enforceImageQuota(settings.optLong("assetsQuota", 536870912))
        downloads.enforceQuota()
        if (!network.online.value || network.metered.value || !services.authentication.hasCredentials()) return@withLock
        val library = services.library
        val rules = settings.optJSONObject("smartRules") ?: JSONObject()
        val targets = mutableSetOf<String>()
        if (rules.optBoolean("enabled")) {
            if (rules.optBoolean("favoriteSongs", true)) {
                var offset = 0
                do { val batch = library.getSongs(LibraryPagination(500, offset), SongFilter(starredOnly = true)); targets += batch.items.map { it.id }; offset += batch.items.size } while (batch.hasMore)
            }
            if (rules.optBoolean("favoritePlaylists", true)) {
                var offset = 0
                do {
                    val batch = library.getPlaylists(LibraryPagination(100, offset))
                    batch.items.filter { it.starredAt != null }.forEach { playlist ->
                        val entries = library.getPlaylist(playlist.id)?.entriesJson ?: "[]"
                        val rows = JSONArray(entries)
                        (0 until rows.length()).forEach { rows.optJSONObject(it)?.optString("id")?.takeIf(String::isNotBlank)?.let(targets::add) }
                    }
                    offset += batch.items.size
                } while (batch.hasMore)
            }
        }
        downloads.cachedAudio().filter { it.source == "smart" && it.songId !in targets }.forEach { downloads.deleteCachedAudio(it.songId) }
        targets.forEach { downloads.download(it, source = "smart") }
        if (settings.optBoolean("syncCoverArt")) {
            val covers = mutableSetOf<String>()
            var offset = 0
            do { val batch = library.getAlbums(LibraryPagination(500, offset), AlbumFilter()); covers += batch.items.map { it.coverArt ?: it.id }; offset += batch.items.size } while (batch.hasMore)
            val player = runCatching { JSONObject(prefs["player_store"] ?: "{}").getJSONObject("state").getJSONObject("settings").getJSONObject("coverArt") }.getOrDefault(JSONObject())
            if (!player.optBoolean("useAlbumCoverForSongs")) {
                offset = 0
                do { val batch = library.getSongs(LibraryPagination(500, offset), SongFilter()); covers += batch.items.mapNotNull { it.coverArt ?: it.albumId }; offset += batch.items.size } while (batch.hasMore)
            }
            val slots = Semaphore(settings.optInt("coverArtConcurrency", 4).coerceIn(1, 8))
            coroutineScope { covers.map { cover -> async { slots.withPermit { runCatching { library.downloadCoverImage(cover, "300") } } } }.awaitAll() }
        }
    }
    fun close() { scope.cancel() }
}
