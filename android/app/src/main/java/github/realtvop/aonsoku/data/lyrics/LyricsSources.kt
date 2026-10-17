package github.realtvop.aonsoku.data.lyrics

import github.realtvop.aonsoku.data.api.SubsonicApi
import github.realtvop.aonsoku.data.api.await
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/** A user-defined lyrics server: its endpoint and an optional `Authorization` value. */
data class CustomLyricsServer(val url: String, val password: String = "")

/**
 * Lyric lookups outside the music server: LRCLIB and a custom lyrics server.
 * Both answer with LRC or plain text; network and format errors surface as
 * exceptions, "nothing found" as null or an empty list.
 */
class LyricsSources(
    private val client: OkHttpClient,
    /** Sent to LRCLIB, which asks clients to identify themselves. */
    private val clientName: String,
    private val lrcLibUrl: String = LRCLIB_URL,
) {
    suspend fun fromLrcLib(song: LyricsSong, artist: String = song.artist): LyricsText? {
        val url = lrcLibUrl.toHttpUrlOrNull()?.newBuilder()
            ?.addQueryParameter("artist_name", artist)
            ?.addQueryParameter("track_name", song.title)
            ?.apply {
                song.durationParam?.let { addQueryParameter("duration", it) }
                if (song.album.isNotEmpty()) addQueryParameter("album_name", song.album)
            }
            ?.build()
            ?: return null
        val request = Request.Builder().url(url).header("Lrclib-Client", clientName).build()
        // A song LRCLIB does not know is a 404 with a JSON body that has no lyrics.
        val body = fetch(request).body
        val found = runCatching { SubsonicApi.json.parseToJsonElement(body) as? JsonObject }.getOrNull()
        val lyrics = found.text("syncedLyrics") ?: found.text("plainLyrics") ?: return null
        return LyricsText(normalize(lyrics))
    }

    /**
     * What [server] has for [song]: the entry with [selectedKey] when it is
     * among the answers, the first entry otherwise. A server may also answer
     * with the lyrics as plain text.
     */
    suspend fun fromCustomServer(
        song: LyricsSong,
        server: CustomLyricsServer,
        selectedKey: String? = null,
    ): LyricsText? {
        val url = server.endpoint()
            ?.apply {
                if (song.title.isNotEmpty()) setQueryParameter("title", song.title)
                if (song.artist.isNotEmpty()) setQueryParameter("artist", song.artist)
                if (song.album.isNotEmpty()) setQueryParameter("album", song.album)
                song.durationParam?.let { setQueryParameter("duration", it) }
                if (song.path.isNotEmpty()) setQueryParameter("path", song.path)
                setQueryParameter("offset", "0")
                setQueryParameter("limit", CANDIDATE_LIMIT)
            }
            ?.build()
            ?: return null
        val response = fetch(server.request(url))
        if (!response.successful) return null
        if (!response.isJson) return normalize(response.body).takeIf { it.isNotEmpty() }?.let(::LyricsText)

        val candidates = parseCandidates(response.body)
        val index = candidates.indices.firstOrNull { candidates[it].key(it) == selectedKey } ?: 0
        val candidate = candidates.getOrNull(index) ?: return null
        return LyricsText(
            value = normalize(candidate.lyrics.orEmpty()),
            romaji = candidate.romaji?.takeIf { it.isNotBlank() }?.let(::normalize),
        )
    }

    /** The entries [server] offers for a title and an artist, for the user to choose from. */
    suspend fun candidates(
        server: CustomLyricsServer,
        title: String?,
        artist: String?,
    ): List<LyricsCandidate> {
        val url = server.endpoint()
            ?.apply {
                title?.trim()?.takeIf { it.isNotEmpty() }?.let { setQueryParameter("title", it) }
                artist?.trim()?.takeIf { it.isNotEmpty() }?.let { setQueryParameter("artist", it) }
            }
            ?.build()
            ?: return emptyList()
        val response = fetch(server.request(url))
        if (!response.successful || !response.isJson) return emptyList()
        return parseCandidates(response.body)
    }

    private fun CustomLyricsServer.endpoint(): HttpUrl.Builder? = url.trim().toHttpUrlOrNull()?.newBuilder()

    private fun CustomLyricsServer.request(url: HttpUrl): Request = Request.Builder()
        .url(url)
        .apply { if (password.isNotEmpty()) header("Authorization", password) }
        .build()

    private class Fetched(val successful: Boolean, val isJson: Boolean, val body: String)

    private suspend fun fetch(request: Request): Fetched = client.newCall(request).await().use { response ->
        Fetched(
            successful = response.isSuccessful,
            isJson = response.header("Content-Type").orEmpty().contains("application/json"),
            body = withContext(Dispatchers.IO) { response.body?.string().orEmpty() },
        )
    }

    /** Entries without lyrics are of no use to anyone. */
    private fun parseCandidates(body: String): List<LyricsCandidate> {
        val array = runCatching { SubsonicApi.json.parseToJsonElement(body) as? JsonArray }.getOrNull()
            ?: return emptyList()
        return runCatching {
            SubsonicApi.json.decodeFromJsonElement(ListSerializer(LyricsCandidate.serializer()), array)
        }.getOrDefault(emptyList()).filter { !it.lyrics.isNullOrBlank() }
    }

    private fun JsonObject?.text(name: String): String? =
        runCatching { this?.get(name)?.jsonPrimitive?.contentOrNull }.getOrNull()?.takeIf { it.isNotBlank() }

    companion object {
        const val LRCLIB_URL = "https://lrclib.net/api/get"
        private const val CANDIDATE_LIMIT = "10"

        fun normalize(lyrics: String): String = lyrics.trim().replace("\r\n", "\n")
    }
}
