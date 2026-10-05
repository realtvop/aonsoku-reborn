package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import android.net.Uri
import github.realtvop.aonsoku.plugins.bridge.AndroidCredentialStore
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.debug.NativeLogger
import java.io.File
import java.net.URLEncoder

class NativeSourceResolver(
    private val context: Context,
    private val credentialsProvider: () -> ServerCredentials?,
) {
    constructor(context: Context) : this(context, {
        AuthenticationService.getInstance(context).getCredentials()
    })

    constructor(context: Context, authenticationService: AuthenticationService) : this(
        context,
        { authenticationService.getCredentials() },
    )

    @Suppress("UNUSED_PARAMETER")
    constructor(context: Context, credentialStore: AndroidCredentialStore) : this(
        context,
        { credentialStore.retrieve() },
    )

    private val cacheDirectories = listOf(
        AudioCacheUtils.getCacheDirectory(context),
        AudioCacheUtils.getSecondaryCacheDirectory(context)
    )

    fun resolveSource(song: QueueSong): Pair<String, String>? {
        // 1. If song.cachedFileUri is provided, check if it exists on disk
        if (!song.cachedFileUri.isNullOrEmpty()) {
            val path = if (song.cachedFileUri.startsWith("file://")) {
                song.cachedFileUri.substring(7)
            } else {
                song.cachedFileUri
            }
            val file = File(path)
            if (file.exists()) {
                return Pair("file://${file.absolutePath}", "native-file")
            }
            NativeLogger.warn("cachedFileUri does not exist on disk: $path", "source-resolver")
        }

        // 2. Check if the file is in local cache directories
        val cacheId = AudioCacheUtils.cacheId(song.id)
        val extensions = listOf("mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "audio")
        for (directory in cacheDirectories) {
            if (directory.exists() && directory.isDirectory) {
                for (ext in extensions) {
                    val file = File(directory, "$cacheId.$ext")
                    if (file.exists()) {
                        return Pair("file://${file.absolutePath}", "native-file")
                    }
                }
            }
        }

        // 3. Direct HTTP/HTTPS URL → pass through unchanged (radio, direct stream)
        if (song.streamUrl.startsWith("http://") || song.streamUrl.startsWith("https://")) {
            return Pair(song.streamUrl, "stream")
        }

        // 4. aonsoku-media://stream → resolve with credentials
        if (song.streamUrl.startsWith("aonsoku-media://stream")) {
            return resolveAonsokuStreamUrl(song)
        }

        NativeLogger.warn("Cannot resolve source: unknown streamUrl scheme for song ${song.id}", "source-resolver")
        return null
    }

    fun resolveCoverArtUrl(coverArtId: String, size: Int = 300): String? {
        val credentials = credentialsProvider()
        if (credentials == null) {
            NativeLogger.warn("Cannot resolve cover art: no credentials", "source-resolver")
            return null
        }

        val cleanBaseUrl = credentials.serverUrl.trimEnd('/')
        val authParams = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion
        )
        val params = authParams + mapOf("id" to coverArtId, "size" to size.toString())
        val queryString = params.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        return "$cleanBaseUrl/rest/getCoverArt?$queryString"
    }

    private fun resolveAonsokuStreamUrl(song: QueueSong): Pair<String, String>? {
        val uri = Uri.parse(song.streamUrl)
        val songId = uri.getQueryParameter("id") ?: song.id
        val maxBitRate = uri.getQueryParameter("maxBitRate")
        val format = uri.getQueryParameter("format")

        val credentials = credentialsProvider()
        if (credentials == null) {
            NativeLogger.error("Cannot resolve aonsoku-media://stream: no credentials for song ${song.id}", "source-resolver")
            return null
        }

        val cleanBaseUrl = credentials.serverUrl.trimEnd('/')
        val authParams = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion
        )
        val extraParams = mutableMapOf(
            "id" to songId,
            "estimateContentLength" to "true"
        )
        if (maxBitRate != null) extraParams["maxBitRate"] = maxBitRate
        if (format != null) extraParams["format"] = format

        val allParams = authParams + extraParams
        val queryString = allParams.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }
        val resolvedUrl = "$cleanBaseUrl/rest/stream?$queryString"
        NativeLogger.debug("Resolved aonsoku-media://stream -> $resolvedUrl", "source-resolver")
        return Pair(resolvedUrl, "stream")
    }
}
