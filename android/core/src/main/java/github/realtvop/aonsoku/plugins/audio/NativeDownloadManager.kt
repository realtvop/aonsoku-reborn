package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import android.net.Uri
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

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
        synchronized(listeners) {
            listeners.forEach { it.onDownloadProgress(songId, loaded, total) }
        }
    }

    private fun emitCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long) {
        synchronized(listeners) {
            listeners.forEach { it.onDownloadCompleted(songId, fileUri, contentType, sizeBytes) }
        }
    }

    private fun emitFailed(songId: String, errorMessage: String) {
        synchronized(listeners) {
            listeners.forEach { it.onDownloadFailed(songId, errorMessage) }
        }
    }

    fun download(songId: String, maxBitRate: Int? = null, format: String? = null) {
        // If already downloading, don't start again
        if (activeJobs.containsKey(songId)) {
            return
        }

        val job = downloadScope.launch {
            try {
                executeDownload(songId, maxBitRate, format)
            } catch (e: CancellationException) {
                // cancelled, do nothing or log
            } catch (e: Exception) {
                emitFailed(songId, e.localizedMessage ?: "Unknown download error")
            } finally {
                activeJobs.remove(songId)
            }
        }
        activeJobs[songId] = job
    }

    fun cancel(songId: String) {
        activeJobs.remove(songId)?.cancel()
    }

    fun cancelAll() {
        val keys = activeJobs.keys()
        while (keys.hasMoreElements()) {
            val songId = keys.nextElement()
            cancel(songId)
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
        connection.connectTimeout = 30000
        connection.readTimeout = 300000
        connection.requestMethod = "GET"
        connection.connect()

        val responseCode = connection.responseCode
        if (responseCode !in 200..299) {
            throw IOException("Server returned HTTP $responseCode")
        }

        val contentType = connection.contentType ?: "audio/mpeg"
        val totalBytes = connection.contentLength.toLong()

        // Stream to a temp file first
        val cacheDir = AudioCacheUtils.getCacheDirectory(context, createIfNeeded = true)
        val tempFile = File.createTempFile("download_${songId}", ".tmp", context.cacheDir)

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
                put("songId", songId)
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
            connection.disconnect()
        }
    }
}
