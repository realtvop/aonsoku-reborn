package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** An audio file that was written to the cache directory. */
data class DownloadedAudio(val file: File, val contentType: String, val sizeBytes: Long)

/**
 * The server answered, and what it sent is not the audio: the song is gone,
 * or the request was refused. Asking again would end the same way.
 */
class AudioUnavailableException(message: String) : IOException(message)

/**
 * Downloads one song into the audio cache directory. Scheduling, the index of
 * what is cached, and quotas belong to [AudioCacheService].
 */
class NativeDownloadManager(
    private val cacheDirectory: () -> File,
    private val tempDirectory: () -> File,
    private val credentials: () -> ServerCredentials?,
) {
    constructor(context: Context, authenticationService: AuthenticationService? = null) : this(
        cacheDirectory = { AudioCacheUtils.getCacheDirectory(context, createIfNeeded = true) },
        tempDirectory = { context.cacheDir },
        credentials = {
            (authenticationService ?: AuthenticationService.getInstance(context)).getCredentials()
        },
    )

    /**
     * Streams [songId] to a temporary file and moves it into the cache once
     * it is complete, so a file in the cache is always whole. [onProgress]
     * gets the bytes read so far and the expected total (0 when unknown), at
     * most a few times per second. Cancelling the caller aborts the transfer.
     */
    suspend fun fetch(
        songId: String,
        maxBitRate: Int? = null,
        format: String? = null,
        onProgress: (loaded: Long, total: Long) -> Unit = { _, _ -> },
    ): DownloadedAudio = coroutineScope {
        val connection = withContext(Dispatchers.IO) { open(songId, maxBitRate, format) }
        // A blocked read does not notice cancellation; closing the socket ends it.
        val watcher = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitCancellation()
            } finally {
                connection.disconnect()
            }
        }
        try {
            withContext(Dispatchers.IO) { receive(connection, songId, onProgress) }
        } catch (error: IOException) {
            // The failure of a transfer that was cancelled is the cancellation.
            ensureActive()
            throw error
        } finally {
            watcher.cancel()
        }
    }

    private fun open(songId: String, maxBitRate: Int?, format: String?): HttpURLConnection {
        // Signed out for now is not the server refusing: the download stays owed.
        val credentials = credentials() ?: throw IOException("No credentials found")
        val params = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion,
        ).toMutableMap()
        params["id"] = songId
        params["estimateContentLength"] = "true"
        if (maxBitRate != null) params["maxBitRate"] = maxBitRate.toString()
        if (format != null) params["format"] = format
        val query = params.entries.joinToString("&") { (key, value) ->
            "${URLEncoder.encode(key, "UTF-8")}=${URLEncoder.encode(value, "UTF-8")}"
        }
        val url = URL("${credentials.serverUrl.trimEnd('/')}/rest/stream?$query")
        return (url.openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            requestMethod = "GET"
        }
    }

    private suspend fun receive(
        connection: HttpURLConnection,
        songId: String,
        onProgress: (loaded: Long, total: Long) -> Unit,
    ): DownloadedAudio {
        var tempFile: File? = null
        try {
            connection.connect()
            val status = connection.responseCode
            if (status !in 200..299) {
                val message = "Server returned HTTP $status"
                // Busy or briefly failing servers are worth another try; a refusal is not.
                val refused = status in 400..499 && status != 408 && status != 429
                throw if (refused) AudioUnavailableException(message) else IOException(message)
            }
            val contentType = connection.contentType ?: "audio/mpeg"
            // Subsonic reports errors as a document with a successful HTTP status.
            if (!isAudio(contentType)) {
                throw AudioUnavailableException("Server returned $contentType instead of audio")
            }
            val total = connection.contentLengthLong.coerceAtLeast(0L)

            val temp = File.createTempFile(TEMP_PREFIX, TEMP_SUFFIX, tempDirectory().apply { mkdirs() })
            tempFile = temp
            connection.inputStream.use { input ->
                FileOutputStream(temp).use { output ->
                    val buffer = ByteArray(BUFFER_BYTES)
                    var loaded = 0L
                    var reportedAt = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        currentCoroutineContext().ensureActive()
                        output.write(buffer, 0, read)
                        loaded += read
                        val now = System.currentTimeMillis()
                        if (now - reportedAt > PROGRESS_INTERVAL_MS) {
                            onProgress(loaded, total)
                            reportedAt = now
                        }
                    }
                    output.flush()
                }
            }
            if (temp.length() == 0L) throw IOException("Server sent no data")

            val directory = cacheDirectory().apply { mkdirs() }
            val cacheId = AudioCacheUtils.cacheId(songId)
            // A copy in another format is replaced, not kept next to the new one.
            AudioCacheUtils.deleteFiles(listOf(directory), songId)
            val destination = File(directory, "$cacheId.${AudioCacheUtils.fileExtension(contentType)}")
            if (!temp.renameTo(destination)) {
                temp.copyTo(destination, overwrite = true)
                temp.delete()
            }
            AudioCacheUtils.metadataFile(directory, songId).writeText(
                JSONObject().apply {
                    put("songId", songId)
                    put("fileName", destination.name)
                    put("contentType", contentType)
                    put("lastModifiedAt", System.currentTimeMillis().toDouble())
                }.toString(),
                Charsets.UTF_8,
            )
            val size = destination.length()
            onProgress(size, size)
            return DownloadedAudio(destination, contentType, size)
        } finally {
            tempFile?.delete()
            connection.disconnect()
        }
    }

    companion object {
        const val TEMP_PREFIX = "download_"
        const val TEMP_SUFFIX = ".tmp"
        private const val CONNECT_TIMEOUT_MS = 30_000
        private const val READ_TIMEOUT_MS = 300_000
        private const val BUFFER_BYTES = 64 * 1024
        private const val PROGRESS_INTERVAL_MS = 200L

        /** Whether a response of this type is the song rather than a message about it. */
        internal fun isAudio(contentType: String): Boolean {
            val type = contentType.substringBefore(';').trim().lowercase()
            return !(type.startsWith("text/") || type.endsWith("json") || type.endsWith("xml") || type.endsWith("html"))
        }
    }
}
