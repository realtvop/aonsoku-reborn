package github.realtvop.aonsoku.data.api

import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.AlbumInfo
import github.realtvop.aonsoku.data.model.AlbumPage
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.ArtistInfo
import github.realtvop.aonsoku.data.model.Genre
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.data.model.Radio
import github.realtvop.aonsoku.data.model.ScanStatus
import github.realtvop.aonsoku.data.model.SearchResult
import github.realtvop.aonsoku.data.model.ServerInfo
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Failure of a Subsonic request, classified like the web `AppRequestError`. */
sealed class ApiException(message: String, cause: Throwable? = null) : IOException(message, cause) {
    class NotSignedIn : ApiException("No stored credentials")

    class NetworkUnreachable(cause: Throwable?) :
        ApiException("The configured server is unreachable", cause)

    class Http(val status: Int) : ApiException("HTTP $status")

    class Parse(message: String) : ApiException(message)

    class AuthFailed(message: String) : ApiException(message)

    class Server(val code: Int, message: String) : ApiException(message)
}

/**
 * Typed Subsonic/OpenSubsonic client for the UI layer. It authenticates with
 * the credentials owned by the native `AuthenticationService`, so screens,
 * playback and sync always talk to the same server with the same identity.
 */
class SubsonicApi(
    private val credentials: () -> ServerCredentials?,
    private val client: OkHttpClient,
    /** Invoked when a request fails at the transport level. */
    private val onUnreachable: () -> Unit = {},
) {
    private data class Payload(val body: JsonObject, val totalCount: Int)

    // region Server

    suspend fun ping(): ServerInfo {
        val payload = request("ping.view")
        return json.decodeFromJsonElement(ServerInfo.serializer(), payload.body)
    }

    suspend fun getScanStatus(): ScanStatus? =
        request("getScanStatus").body.decode("scanStatus", ScanStatus.serializer())

    suspend fun startScan(): ScanStatus? =
        request("startScan").body.decode("scanStatus", ScanStatus.serializer())

    // endregion

    // region Albums

    suspend fun getAlbumList(
        type: String,
        size: Int = 30,
        offset: Int = 0,
        fromYear: Int? = null,
        toYear: Int? = null,
        genre: String? = null,
    ): AlbumPage {
        val payload = request(
            "getAlbumList2",
            "type" to type,
            "size" to size.toString(),
            "offset" to offset.toString(),
            "fromYear" to fromYear?.toString(),
            "toYear" to toYear?.toString(),
            "genre" to genre,
        )
        val albums = payload.body.obj("albumList2").decodeList("album", Album.serializer())
        return AlbumPage(albums, payload.totalCount)
    }

    suspend fun getAlbum(id: String): Album? =
        request("getAlbum", "id" to id).body.decode("album", Album.serializer())

    suspend fun getAlbumInfo(id: String): AlbumInfo? =
        request("getAlbumInfo2", "id" to id).body.decode("albumInfo", AlbumInfo.serializer())

    // endregion

    // region Artists

    suspend fun getArtists(): List<Artist> {
        val indexes = request("getArtists").body.obj("artists").list("index")
        return indexes
            .flatMap { (it as? JsonObject).decodeList("artist", Artist.serializer()) }
            .sortedBy { it.name.lowercase() }
    }

    suspend fun getArtist(id: String): Artist? =
        request("getArtist", "id" to id).body.decode("artist", Artist.serializer())

    suspend fun getArtistInfo(id: String): ArtistInfo? =
        request("getArtistInfo", "id" to id).body.decode("artistInfo", ArtistInfo.serializer())

    suspend fun getTopSongs(artistName: String): List<Song> =
        request("getTopSongs", "artist" to artistName).body
            .obj("topSongs")
            .decodeList("song", Song.serializer())

    // endregion

    // region Songs

    suspend fun getSong(id: String): Song? =
        request("getSong", "id" to id).body.decode("song", Song.serializer())

    suspend fun getRandomSongs(
        size: Int,
        genre: String? = null,
        fromYear: Int? = null,
        toYear: Int? = null,
    ): List<Song> = request(
        "getRandomSongs",
        "size" to size.toString(),
        "genre" to genre,
        "fromYear" to fromYear?.toString(),
        "toYear" to toYear?.toString(),
    ).body.obj("randomSongs").decodeList("song", Song.serializer())

    suspend fun getStarred(): SearchResult {
        val starred = request("getStarred2").body.obj("starred2")
        return SearchResult(
            artist = starred.decodeList("artist", Artist.serializer()),
            album = starred.decodeList("album", Album.serializer()),
            song = starred.decodeList("song", Song.serializer()),
        )
    }

    suspend fun search(
        query: String,
        artistCount: Int = 20,
        artistOffset: Int = 0,
        albumCount: Int = 20,
        albumOffset: Int = 0,
        songCount: Int = 20,
        songOffset: Int = 0,
    ): SearchResult {
        // Navidrome lists everything for a quoted empty query; other servers
        // expect a plain empty string.
        val serverType = credentials()?.serverType
        val everything = if (serverType == "navidrome") "\"\"" else ""
        val result = request(
            "search3",
            "query" to query.ifEmpty { everything },
            "artistCount" to artistCount.toString(),
            "artistOffset" to artistOffset.toString(),
            "albumCount" to albumCount.toString(),
            "albumOffset" to albumOffset.toString(),
            "songCount" to songCount.toString(),
            "songOffset" to songOffset.toString(),
        ).body.obj("searchResult3")
        return SearchResult(
            artist = result.decodeList("artist", Artist.serializer()),
            album = result.decodeList("album", Album.serializer()),
            song = result.decodeList("song", Song.serializer()),
        )
    }

    suspend fun star(id: String) {
        request("star", "id" to id)
    }

    suspend fun unstar(id: String) {
        request("unstar", "id" to id)
    }

    suspend fun getGenres(): List<Genre> =
        request("getGenres").body.obj("genres").decodeList("genre", Genre.serializer())

    // endregion

    // region Playlists

    suspend fun getPlaylists(): List<Playlist> =
        request("getPlaylists").body.obj("playlists").decodeList("playlist", Playlist.serializer())

    suspend fun getPlaylist(id: String): Playlist? =
        request("getPlaylist", "id" to id).body.decode("playlist", Playlist.serializer())

    suspend fun createPlaylist(name: String, songIds: List<String> = emptyList()): Playlist? =
        request(
            "createPlaylist",
            listOf("name" to name) + songIds.map { "songId" to it },
        ).body.decode("playlist", Playlist.serializer())

    suspend fun updatePlaylist(
        playlistId: String,
        name: String? = null,
        comment: String? = null,
        isPublic: Boolean? = null,
        songIdsToAdd: List<String> = emptyList(),
        songIndexesToRemove: List<Int> = emptyList(),
    ) {
        val params = buildList {
            add("playlistId" to playlistId)
            name?.let { add("name" to it) }
            comment?.let { add("comment" to it) }
            isPublic?.let { add("public" to it.toString()) }
            songIdsToAdd.forEach { add("songIdToAdd" to it) }
            songIndexesToRemove.forEach { add("songIndexToRemove" to it.toString()) }
        }
        request("updatePlaylist", params)
    }

    suspend fun deletePlaylist(id: String) {
        request("deletePlaylist", "id" to id)
    }

    // endregion

    // region Radios

    suspend fun getRadios(): List<Radio> =
        request("getInternetRadioStations").body
            .obj("internetRadioStations")
            .decodeList("internetRadioStation", Radio.serializer())

    suspend fun createRadio(name: String, streamUrl: String, homePageUrl: String) {
        request(
            "createInternetRadioStation",
            listOf("streamUrl" to streamUrl, "name" to name, "homepageUrl" to homePageUrl),
            post = true,
        )
    }

    suspend fun updateRadio(radio: Radio) {
        request(
            "updateInternetRadioStation",
            "id" to radio.id,
            "streamUrl" to radio.streamUrl,
            "name" to radio.name,
            "homepageUrl" to radio.homePageUrl.orEmpty(),
        )
    }

    suspend fun deleteRadio(id: String) {
        request("deleteInternetRadioStation", "id" to id)
    }

    // endregion

    // region Lyrics

    /** OpenSubsonic structured lyrics; returns the raw `lyricsList` object. */
    suspend fun getLyricsBySongId(id: String): JsonObject? =
        request("getLyricsBySongId", "id" to id).body["lyricsList"] as? JsonObject

    /** Classic Subsonic lyrics lookup by artist and title. */
    suspend fun getLyrics(artist: String, title: String): JsonObject? =
        request("getLyrics", "artist" to artist, "title" to title).body["lyrics"] as? JsonObject

    // endregion

    // region URLs

    /** Authenticated cover-art URL for callers that cannot use the image cache. */
    fun coverArtUrl(id: String, size: Int = 300): String? =
        buildUrl("getCoverArt", listOf("id" to id, "size" to size.toString()))?.toString()

    // endregion

    private suspend fun request(path: String, vararg params: Pair<String, String?>): Payload =
        request(path, params.toList())

    private suspend fun request(
        path: String,
        params: List<Pair<String, String?>>,
        post: Boolean = false,
    ): Payload {
        val url = buildUrl(path, params) ?: throw ApiException.NotSignedIn()
        val request = Request.Builder()
            .url(url)
            .header("Accept", "application/json")
            .apply { if (post) post(ByteArray(0).toRequestBody()) else get() }
            .build()

        val text = try {
            client.newCall(request).await().use { response ->
                if (!response.isSuccessful) throw ApiException.Http(response.code)
                val total = response.header("x-total-count")?.toIntOrNull() ?: 0
                val body = withContext(Dispatchers.IO) { response.body?.string().orEmpty() }
                body to total
            }
        } catch (error: ApiException) {
            throw error
        } catch (error: IOException) {
            onUnreachable()
            throw ApiException.NetworkUnreachable(error)
        }

        return withContext(Dispatchers.Default) {
            val root = try {
                json.parseToJsonElement(text.first).jsonObject
            } catch (_: Exception) {
                throw ApiException.Parse("Failed to parse response")
            }
            val payload = root["subsonic-response"] as? JsonObject
                ?: throw ApiException.Parse("Missing subsonic response payload")
            if (payload["status"]?.jsonPrimitive?.content == "failed") {
                val error = payload["error"] as? JsonObject
                val code = runCatching { error?.get("code")?.jsonPrimitive?.int }.getOrNull() ?: 0
                val message = error?.get("message")?.jsonPrimitive?.content
                    ?.takeIf { it.isNotBlank() }
                    ?: "Server returned a failed response"
                if (code == 40 || code == 41) throw ApiException.AuthFailed(message)
                throw ApiException.Server(code, message)
            }
            Payload(payload, text.second)
        }
    }

    private fun buildUrl(path: String, params: List<Pair<String, String?>>): HttpUrl? {
        val current = credentials() ?: return null
        val base = "${current.serverUrl.trimEnd('/')}/rest/${path.trimStart('/')}"
            .toHttpUrlOrNull() ?: return null
        val builder = base.newBuilder()
        SubsonicAuthBuilder.buildQueryParams(
            username = current.username,
            password = current.password,
            authType = current.authType,
            protocolVersion = current.protocolVersion,
        ).forEach { (name, value) -> builder.addQueryParameter(name, value) }
        for ((name, value) in params) {
            if (value != null) builder.addQueryParameter(name, value)
        }
        return builder.build()
    }

    private fun JsonObject?.obj(name: String): JsonObject? = this?.get(name) as? JsonObject

    /** Tolerates servers that collapse a one-element array into an object. */
    private fun JsonObject?.list(name: String): List<JsonElement> =
        when (val value = this?.get(name)) {
            null, JsonNull -> emptyList()
            is JsonArray -> value
            else -> listOf(value)
        }

    private fun <T> JsonObject?.decodeList(name: String, serializer: DeserializationStrategy<T>): List<T> =
        list(name).mapNotNull { element ->
            runCatching { json.decodeFromJsonElement(serializer, element) }.getOrNull()
        }

    private fun <T> JsonObject.decode(name: String, serializer: DeserializationStrategy<T>): T? {
        val value = get(name) ?: return null
        if (value is JsonNull) return null
        return try {
            json.decodeFromJsonElement(serializer, value)
        } catch (error: Exception) {
            throw ApiException.Parse(error.message ?: "Unexpected response shape")
        }
    }

    companion object {
        val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            coerceInputValues = true
            explicitNulls = false
        }

        inline fun <reified T> encodeList(items: List<T>): String =
            json.encodeToString(ListSerializer(serializer<T>()), items)

        inline fun <reified T> decodeList(raw: String): List<T> =
            runCatching { json.decodeFromString(ListSerializer(serializer<T>()), raw) }
                .getOrDefault(emptyList())
    }
}

/** Suspends until the call completes and cancels it with the coroutine. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (!continuation.isCancelled) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response)
            }
        },
    )
}
