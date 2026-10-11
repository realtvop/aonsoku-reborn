package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import android.net.Uri
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.plugins.data.NativeLibraryCodec
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

data class NativeDownloadState(val songId: String, val status: String, val loaded: Long = 0, val total: Long = 0, val error: String? = null, val source: String = "explicit")
data class NativeCachedAudio(val songId: String, val sizeBytes: Long, val source: String)

class NativeDownloadManager(
    private val context: Context,
    private val authenticationService: AuthenticationService? = null,
) {
    interface Listener {
        fun onDownloadProgress(songId: String, loaded: Long, total: Long)
        fun onDownloadCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long)
        fun onDownloadFailed(songId: String, errorMessage: String)
    }

    private val listeners = mutableListOf<Listener>()
    private val activeJobs = ConcurrentHashMap<String, Job>()
    private val downloadScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val slots = Semaphore(3)
    private val _states = MutableStateFlow<Map<String, NativeDownloadState>>(emptyMap())
    val states = _states.asStateFlow()
    private val sources = ConcurrentHashMap<String, String>()
    private val pending = ConcurrentHashMap<String, JSONObject>()
    private val connections = ConcurrentHashMap<String, HttpURLConnection>()
    private val journal get() = File(context.filesDir, "native-downloads.json")

    init {
        runCatching {
            val saved = JSONArray(journal.takeIf(File::exists)?.readText() ?: "[]")
            (0 until saved.length()).forEach { index ->
                val request = saved.getJSONObject(index)
                download(request.getString("songId"), request.optInt("maxBitRate").takeIf { it > 0 }, request.optString("format").takeIf(String::isNotBlank), request.optString("source", "explicit"))
            }
        }
    }
    @Synchronized
    private fun persistPending() {
        val temporary = File(context.filesDir, "native-downloads.tmp")
        temporary.writeText(JSONArray(pending.values.toList()).toString())
        check(temporary.renameTo(journal)) { "Cannot persist download queue" }
    }
    fun retryPending() {
        pending.values.toList().forEach { request -> download(request.getString("songId"), request.optInt("maxBitRate").takeIf { it > 0 }, request.optString("format").takeIf(String::isNotBlank), request.optString("source", "explicit")) }
    }

    fun addListener(listener: Listener) {
        synchronized(listeners) {
            if (!listeners.contains(listener)) {
                listeners.add(listener)
            }
        }
    }

    fun removeListener(listener: Listener) {
        synchronized(listeners) {
            listeners.remove(listener)
        }
    }

    private fun emitProgress(songId: String, loaded: Long, total: Long) {
        _states.update { it + (songId to NativeDownloadState(songId, "downloading", loaded, total, source = sources[songId] ?: "explicit")) }
        synchronized(listeners) {
            listeners.forEach { it.onDownloadProgress(songId, loaded, total) }
        }
    }

    private fun emitCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long) {
        _states.update { it + (songId to NativeDownloadState(songId, "completed", sizeBytes, sizeBytes, source = sources[songId] ?: "explicit")) }
        synchronized(listeners) {
            listeners.forEach { it.onDownloadCompleted(songId, fileUri, contentType, sizeBytes) }
        }
    }

    private fun emitFailed(songId: String, errorMessage: String) {
        _states.update { it + (songId to NativeDownloadState(songId, "failed", error = errorMessage, source = sources[songId] ?: "explicit")) }
        synchronized(listeners) {
            listeners.forEach { it.onDownloadFailed(songId, errorMessage) }
        }
    }

    @Synchronized
    fun download(songId: String, maxBitRate: Int? = null, format: String? = null, source: String = "explicit") {
        if (songId.startsWith("radio:")) return
        require(source in setOf("explicit", "smart", "lru"))
        val previousSource = sources[songId] ?: cachedAudio().find { it.songId == songId }?.source
        val effectiveSource = promotedSource(previousSource, source)
        sources[songId] = effectiveSource
        if (activeJobs.containsKey(songId)) { pending[songId]?.put("source", effectiveSource); persistPending(); return }
        val cached = cachedAudio().find { it.songId == songId }
        if (cached != null) {
            if (effectiveSource != cached.source) {
                val file = AudioCacheUtils.getMetadataFile(context, songId)
                runCatching { val json = JSONObject(file.readText()); json.put("source", effectiveSource); file.writeText(json.toString()) }
            }
            _states.update { it + (songId to NativeDownloadState(songId, "completed", cached.sizeBytes, cached.sizeBytes, source = effectiveSource)) }
            return
        }
        pending[songId] = JSONObject().put("songId", songId).put("source", effectiveSource).put("maxBitRate", maxBitRate).put("format", format)
        persistPending()
        _states.update { it + (songId to NativeDownloadState(songId, "queued", source = effectiveSource)) }
        val job = downloadScope.launch(start = CoroutineStart.LAZY) {
            try { slots.withPermit { executeDownload(songId, maxBitRate, format) }; pending.remove(songId); persistPending(); enforceQuota(songId) }
            catch (e: CancellationException) { _states.update { if (songId in it) it + (songId to NativeDownloadState(songId, "cancelled", source = source)) else it } }
            catch (e: Exception) { emitFailed(songId, e.localizedMessage ?: "Download failed") }
            finally { activeJobs.remove(songId, coroutineContext[Job]) }
        }
        activeJobs[songId] = job
        job.start()
    }

    fun cachedAudio(): List<NativeCachedAudio> = listOf(AudioCacheUtils.getCacheDirectory(context), AudioCacheUtils.getSecondaryCacheDirectory(context)).flatMap { dir ->
        dir.listFiles()?.filter { it.extension == "json" }?.mapNotNull { file ->
            runCatching {
                val json = JSONObject(file.readText())
                val audio = File(dir, json.getString("fileName"))
                if (audio.isFile) NativeCachedAudio(json.getString("songId"), audio.length(), json.optString("source", "lru")) else null
            }.getOrNull()
        }.orEmpty()
    }.distinctBy { it.songId }

    fun cachedSong(songId: String): SongEntity? {
        return listOf(AudioCacheUtils.getCacheDirectory(context), AudioCacheUtils.getSecondaryCacheDirectory(context)).firstNotNullOfOrNull { dir ->
            runCatching {
                val raw = JSONObject(File(dir, "${AudioCacheUtils.cacheId(songId)}.json").readText())
                if (!File(dir, raw.getString("fileName")).isFile) null
                else raw.optJSONObject("song")?.let { NativeLibraryCodec.parseSong(it) } ?: SongEntity(id = songId, title = songId)
            }.getOrNull()
        }
    }
    @Synchronized
    fun deleteCachedAudio(songId: String) {
        cancel(songId)
        val id = AudioCacheUtils.cacheId(songId)
        listOf(AudioCacheUtils.getCacheDirectory(context), AudioCacheUtils.getSecondaryCacheDirectory(context)).forEach { dir -> dir.listFiles()?.filter { it.name.startsWith("$id.") }?.forEach(File::delete) }
        _states.update { it - songId }
    }
    fun clearSource(source: String) {
        pending.values.filter { it.optString("source") == source }.map { it.getString("songId") }.forEach(::cancel)
        cachedAudio().filter { it.source == source }.forEach { deleteCachedAudio(it.songId) } }
    suspend fun enforceQuota(protectedSongId: String? = null) {
        val prefs = PreferencesService.getInstance(context).getAllPreferences()
        val settings = runCatching { JSONObject(prefs["cache_store"] ?: "{}").getJSONObject("state").getJSONObject("settings") }.getOrDefault(JSONObject())
        val quota = settings.optLong("lruQuota", 1024L * 1024 * 1024)
        if (quota <= 0) return
        val entries = cachedAudio().filter { it.source == "lru" }
        var size = entries.sumOf { it.sizeBytes }
        entries.sortedBy { AudioCacheUtils.getMetadataFile(context, it.songId).lastModified() }.forEach {
            if (size > quota && it.songId != protectedSongId && !activeJobs.containsKey(it.songId)) { deleteCachedAudio(it.songId); size -= it.sizeBytes }
        }
    }

    fun cancel(songId: String) {
        if (pending.remove(songId) != null) persistPending()
        connections.remove(songId)?.disconnect()
        activeJobs.remove(songId)?.cancel()
    }

    fun pauseAll() { activeJobs.values.toList().forEach(Job::cancel); connections.values.toList().forEach { it.disconnect() } }
    fun close() { pauseAll(); downloadScope.cancel() }
    fun cancelAll() {
        val keys = activeJobs.keys()
        while (keys.hasMoreElements()) {
            val songId = keys.nextElement()
            cancel(songId)
        }
    }

    companion object {
        /** Explicit downloads cannot be evicted by a later background-cache request. */
        internal fun promotedSource(existing: String?, requested: String): String {
            val priority = mapOf("lru" to 0, "smart" to 1, "explicit" to 2)
            return if ((priority[existing] ?: -1) > (priority[requested] ?: 0)) existing!! else requested
        }
    }
    private suspend fun executeDownload(songId: String, maxBitRate: Int?, format: String?) {
        val credentials = (authenticationService ?: AuthenticationService.getInstance(context))
            .getCredentials()
            ?: throw IOException("No credentials found")

        val baseString = "${credentials.serverUrl.trimEnd('/')}/rest/stream"
        val authParams = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion
        )

        val params = authParams.toMutableMap()
        params["id"] = songId
        params["estimateContentLength"] = "true"
        if (maxBitRate != null) params["maxBitRate"] = maxBitRate.toString()
        if (format != null) params["format"] = format

        val queryString = params.entries.joinToString("&") { (key, value) ->
            "${URLEncoder.encode(key, "UTF-8")}=${URLEncoder.encode(value, "UTF-8")}"
        }

        val url = URL("$baseString?$queryString")
        val connection = url.openConnection() as HttpURLConnection
        connections[songId] = connection
        connection.connectTimeout = 30000
        connection.readTimeout = 300000
        connection.requestMethod = "GET"
        connection.connect()

        val responseCode = connection.responseCode
        if (responseCode !in 200..299) {
            connection.disconnect(); connections.remove(songId, connection); throw IOException("Server returned HTTP $responseCode")
        }

        val contentType = connection.contentType ?: "audio/mpeg"
        if (contentType.contains("json") || contentType.contains("xml") || contentType.contains("text/html")) { connection.disconnect(); throw IOException("Server did not return audio") }
        val totalBytes = connection.contentLength.toLong()

        // Stream to a temp file first
        val cacheDir = AudioCacheUtils.getCacheDirectory(context, createIfNeeded = true)
        val tempFile = File.createTempFile("download_${AudioCacheUtils.cacheId(songId)}", ".tmp", context.cacheDir)

        try {
            connection.inputStream.use { input ->
                FileOutputStream(tempFile).use { output ->
                    val buffer = ByteArray(64 * 1024) // 64KB chunks
                    var bytesRead: Int
                    var totalRead = 0L
                    var lastReportedTime = 0L

                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        yield() // support cancellation
                        output.write(buffer, 0, bytesRead)
                        totalRead += bytesRead

                        val now = System.currentTimeMillis()
                        // Throttle progress updates to at most once per 200ms
                        if (now - lastReportedTime > 200) {
                            emitProgress(songId, totalRead, if (totalBytes > 0) totalBytes else 0L)
                            lastReportedTime = now
                        }
                    }
                    if (totalBytes > 0 && totalRead < totalBytes) throw IOException("Incomplete audio download")
                    output.flush()
                }
            }

            // Move temp file to destination
            val ext = AudioCacheUtils.fileExtension(contentType)
            val cacheId = AudioCacheUtils.cacheId(songId)
            val destFile = File(cacheDir, "$cacheId.$ext")

            if (destFile.exists()) {
                destFile.delete()
            }
            if (!tempFile.renameTo(destFile)) {
                // If rename fails, copy and delete
                tempFile.copyTo(destFile, overwrite = true)
                tempFile.delete()
            }

            // Write metadata JSON file
            val metadataFile = AudioCacheUtils.getMetadataFile(context, songId)
            val metadataJson = JSONObject().apply {
                LibraryService.getInstance(context).getSong(songId)?.let { song -> put("song", JSONObject().put("id", song.id).put("title", song.title).put("artist", song.artist).put("artistId", song.artistId).put("album", song.album).put("albumId", song.albumId).put("duration", song.duration).put("coverArt", song.coverArt)) }
                put("songId", songId)
                put("source", sources[songId] ?: "explicit")
                put("fileName", destFile.name)
                put("contentType", contentType)
                put("lastModifiedAt", System.currentTimeMillis().toDouble())
            }
            metadataFile.writeText(metadataJson.toString(), Charsets.UTF_8)

            val finalSize = destFile.length()
            emitCompleted(songId, Uri.fromFile(destFile).toString(), contentType, finalSize)
        } finally {
            if (tempFile.exists()) {
                tempFile.delete()
            }
            connections.remove(songId, connection)
            connection.disconnect()
        }
    }
}
