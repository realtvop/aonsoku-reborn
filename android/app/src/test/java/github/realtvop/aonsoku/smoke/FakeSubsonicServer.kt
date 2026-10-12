package github.realtvop.aonsoku.smoke

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO

/**
 * A small in-process Subsonic server (Navidrome flavored) with a fixed
 * library. It answers what sign-in, library sync, and the screens request, and
 * records the endpoints that were called.
 */
class FakeSubsonicServer {
    private val server = MockWebServer()

    /** Endpoint names in the order they were requested, without `.view`. */
    val requests = CopyOnWriteArrayList<String>()

    val artists = listOf(
        FakeArtist("ar-1", "Aurora Lane"),
        FakeArtist("ar-2", "Blue Meridian"),
        FakeArtist("ar-3", "Cedar and Stone"),
    )

    val albums = listOf(
        FakeAlbum("al-1", "Northern Lights", artists[0], 2021, "Indie", discs = 2, "2024-05-01T10:00:00Z"),
        FakeAlbum("al-2", "Paper Boats", artists[0], 2019, "Indie", discs = 1, "2024-04-01T10:00:00Z"),
        FakeAlbum("al-3", "Tidal Hours", artists[1], 2023, "Electronic", discs = 1, "2024-03-01T10:00:00Z"),
        FakeAlbum("al-4", "Low Sun", artists[1], 2018, "Electronic", discs = 1, "2024-02-01T10:00:00Z"),
        FakeAlbum("al-5", "Hearthside", artists[2], 2020, "Folk", discs = 1, "2024-01-01T10:00:00Z"),
    )

    val songs: List<FakeSong> = buildList {
        add(albums[0], "First Snow", "Polar Night", "Green Sky", "Thaw")
        add(albums[1], "Harbor", "Fold", "Drift")
        add(albums[2], "Low Tide", "Undertow", "Slack Water")
        add(albums[3], "Low Sun")
        add(albums[4], "Kindling", "Embers", "Ash")
    }

    val playlists = mutableListOf(
        FakePlaylist("pl-1", "Morning Mix", "Songs for the first coffee", listOf(0, 4, 7, 0)),
        FakePlaylist("pl-2", "Empty Crate", "", emptyList()),
    )

    private val starredSongs = mutableSetOf(songs[0].id, songs[8].id)
    private val starredAlbums = mutableSetOf(albums[2].id)

    val url: String get() = server.url("/").toString().trimEnd('/')

    /** The server also stands in for LRCLIB and for a custom lyrics server. */
    val lrcLibUrl: String get() = "$url/lrclib"
    val customLyricsUrl: String get() = "$url/custom-lyrics"

    /** The `Authorization` header of the last request to the custom lyrics server. */
    @Volatile
    var customLyricsAuthorization: String? = null
        private set

    fun start() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = runCatching {
                respond(request)
            }.getOrElse { failed(0, it.toString()) }
        }
        server.start()
    }

    fun shutdown() {
        runCatching { server.shutdown() }
    }

    fun requested(endpoint: String): Boolean = endpoint in requests

    private fun respond(request: RecordedRequest): MockResponse {
        val url = request.requestUrl ?: return failed(0, "no url")
        val endpoint = url.pathSegments.last().removeSuffix(".view")
        requests += endpoint
        fun param(name: String): String? = url.queryParameter(name)
        fun int(name: String, default: Int): Int = param(name)?.toIntOrNull() ?: default

        return when (endpoint) {
            "ping", "scrobble", "startScan" -> ok()
            "getArtists" -> ok("artists", artistIndex())
            "getArtist" -> artists.find { it.id == param("id") }
                ?.let { artist ->
                    ok(
                        "artist",
                        artistJson(artist).put("album", albumArray(albums.filter { it.artist == artist })),
                    )
                }
                ?: notFound()
            "getArtistInfo", "getArtistInfo2" -> ok(
                if (endpoint == "getArtistInfo") "artistInfo" else "artistInfo2",
                JSONObject()
                    .put("biography", "A <b>fictional</b> act. <a href=\"https://example.org\">Read more</a>")
                    .put("lastFmUrl", "https://www.last.fm/music/fake")
                    .put("musicBrainzId", "0000-fake")
                    .put(
                        "similarArtist",
                        JSONArray(artists.filter { it.id != param("id") }.map(::artistJson)),
                    ),
            )
            "getAlbumList2" -> ok(
                "albumList2",
                JSONObject().put(
                    "album",
                    albumArray(albumList(param("type"), param("genre")).page(int("offset", 0), int("size", 10))),
                ),
            )
            "getAlbum" -> albums.find { it.id == param("id") }
                ?.let { album ->
                    ok("album", albumJson(album).put("song", songArray(songs.filter { it.album == album })))
                }
                ?: notFound()
            "getAlbumInfo", "getAlbumInfo2" -> ok(
                "albumInfo",
                JSONObject()
                    .put("notes", "Recorded for the smoke tests.")
                    .put("lastFmUrl", "https://www.last.fm/music/fake/album"),
            )
            "getSong" -> songs.find { it.id == param("id") }?.let { ok("song", songJson(it)) }
                ?: notFound()
            "getTopSongs" -> ok(
                "topSongs",
                JSONObject().put(
                    "song",
                    songArray(songs.filter { it.album.artist.name == param("artist") }.take(int("count", 10))),
                ),
            )
            "getRandomSongs" -> ok(
                "randomSongs",
                JSONObject().put("song", songArray(songs.take(int("size", 10)))),
            )
            "getStarred2" -> ok(
                "starred2",
                JSONObject()
                    .put("artist", JSONArray())
                    .put("album", albumArray(albums.filter { it.id in starredAlbums }))
                    .put("song", songArray(songs.filter { it.id in starredSongs })),
            )
            "star", "unstar" -> {
                val starred = endpoint == "star"
                url.queryParameterValues("id").filterNotNull().forEach {
                    if (starred) starredSongs += it else starredSongs -= it
                }
                url.queryParameterValues("albumId").filterNotNull().forEach {
                    if (starred) starredAlbums += it else starredAlbums -= it
                }
                ok()
            }
            "getPlaylists" -> ok(
                "playlists",
                JSONObject().put("playlist", JSONArray(playlists.map(::playlistJson))),
            )
            "getPlaylist" -> playlists.find { it.id == param("id") }
                ?.let { playlist ->
                    ok(
                        "playlist",
                        playlistJson(playlist).put("entry", songArray(playlist.songs.map { songs[it] })),
                    )
                }
                ?: notFound()
            "createPlaylist" -> {
                val created = FakePlaylist(
                    id = "pl-${playlists.size + 1}",
                    name = param("name").orEmpty(),
                    comment = "",
                    songs = url.queryParameterValues("songId").filterNotNull()
                        .map { id -> songs.indexOfFirst { it.id == id } }
                        .filter { it >= 0 },
                )
                playlists += created
                ok("playlist", playlistJson(created).put("entry", songArray(created.songs.map { songs[it] })))
            }
            "updatePlaylist" -> ok()
            "deletePlaylist" -> {
                playlists.removeAll { it.id == param("id") }
                ok()
            }
            "getGenres" -> ok(
                "genres",
                JSONObject().put(
                    "genre",
                    JSONArray(
                        albums.groupBy { it.genre }.map { (genre, list) ->
                            JSONObject()
                                .put("value", genre)
                                .put("albumCount", list.size)
                                .put("songCount", songs.count { it.album.genre == genre })
                        },
                    ),
                ),
            )
            "search3" -> {
                val query = param("query").orEmpty().trim('"').lowercase()
                fun <T> List<T>.matching(name: (T) -> String) =
                    filter { query.isEmpty() || name(it).lowercase().contains(query) }
                ok(
                    "searchResult3",
                    JSONObject()
                        .put(
                            "artist",
                            JSONArray(
                                artists.matching { it.name }
                                    .page(int("artistOffset", 0), int("artistCount", 20))
                                    .map(::artistJson),
                            ),
                        )
                        .put(
                            "album",
                            albumArray(
                                albums.matching { it.name }.page(int("albumOffset", 0), int("albumCount", 20)),
                            ),
                        )
                        .put(
                            "song",
                            songArray(
                                songs.matching { it.title }.page(int("songOffset", 0), int("songCount", 20)),
                            ),
                        ),
                )
            }
            "getInternetRadioStations" -> ok(
                "internetRadioStations",
                JSONObject().put(
                    "internetRadioStation",
                    JSONArray(
                        listOf(
                            JSONObject()
                                .put("id", "ra-1")
                                .put("name", "Harbor FM")
                                .put("streamUrl", "$url/radio/stream")
                                .put("homePageUrl", "https://example.org/harbor"),
                        ),
                    ),
                ),
            )
            "createInternetRadioStation", "updateInternetRadioStation", "deleteInternetRadioStation" -> ok()
            "getScanStatus" -> ok(
                "scanStatus",
                JSONObject().put("scanning", false).put("count", songs.size),
            )
            // "Low Tide" has structured lyrics with a translation, "Undertow" LRC
            // text, "Slack Water" only what LRCLIB knows, and the rest nothing.
            "getLyricsBySongId" -> ok(
                "lyricsList",
                JSONObject().put(
                    "structuredLyrics",
                    if (param("id") == songs[LOW_TIDE].id) structuredLyrics() else JSONArray(),
                ),
            )
            "getLyrics" -> ok(
                "lyrics",
                if (param("title") == songs[UNDERTOW].title) {
                    JSONObject()
                        .put("artist", param("artist"))
                        .put("title", param("title"))
                        .put("value", "[00:00.20]Pulled under\n[00:01.50]By the undertow\n[00:02.50]And out again")
                } else {
                    JSONObject()
                },
            )
            "lrclib" -> if (param("track_name") == songs[SLACK_WATER].title) {
                MockResponse()
                    .setHeader("Content-Type", "application/json")
                    .setBody(
                        JSONObject()
                            .put("id", 1)
                            .put("plainLyrics", "Still water\nBetween the tides\n\nNothing pulls, nothing pushes")
                            .put("syncedLyrics", JSONObject.NULL)
                            .toString(),
                    )
            } else {
                MockResponse()
                    .setResponseCode(404)
                    .setHeader("Content-Type", "application/json")
                    .setBody(JSONObject().put("code", 404).put("name", "TrackNotFound").toString())
            }
            "custom-lyrics" -> {
                customLyricsAuthorization = request.getHeader("Authorization")
                val title = param("title").orEmpty()
                MockResponse()
                    .setHeader("Content-Type", "application/json")
                    .setBody(
                        JSONArray()
                            .put(
                                JSONObject()
                                    .put("id", "entry-1")
                                    .put("title", title)
                                    .put("artist", param("artist").orEmpty())
                                    .put("lyrics", "[00:00.20]First entry of $title\n[00:02.00]Its second line"),
                            )
                            .put(
                                JSONObject()
                                    .put("id", "entry-2")
                                    .put("title", "$title (Live)")
                                    .put("artist", param("artist").orEmpty())
                                    .put("lyrics", "[00:00.20]Second entry of $title\n[00:02.00]Sung live")
                                    .put("romaji", "[00:00.20]Sekando entori"),
                            )
                            .toString(),
                    )
            }
            "getCoverArt", "getAvatar" -> MockResponse()
                .setHeader("Content-Type", "image/png")
                .setBody(Buffer().write(artwork(param("id") ?: param("username").orEmpty())))
            // Served slowly: the shadowed audio output plays as fast as data
            // arrives, and a song that stays current is what tests can rely on.
            "stream", "download" -> MockResponse()
                .setHeader("Content-Type", "audio/wav")
                .setBody(Buffer().write(audio))
                .throttleBody(STREAM_BYTES_PER_SECOND, 1, TimeUnit.SECONDS)
            else -> failed(0, "Not implemented: $endpoint")
        }
    }

    /** Timed lines that fit into the few seconds of audio, with a long pause in between. */
    private fun structuredLyrics(): JSONArray {
        fun track(lang: String, vararg lines: Pair<Int, String>) = JSONObject()
            .put("lang", lang)
            .put("synced", true)
            .put(
                "line",
                JSONArray(lines.map { (start, value) -> JSONObject().put("start", start).put("value", value) }),
            )
        return JSONArray()
            .put(
                track(
                    "eng",
                    0 to "The tide goes out",
                    800 to "And leaves the shore to me",
                    1_500 to "",
                    2_000 to "Low tide, low tide",
                    2_600 to "Carry what I cannot keep",
                ),
            )
            .put(
                track(
                    "spa",
                    0 to "La marea baja",
                    800 to "Y me deja la orilla",
                    2_000 to "Marea baja, marea baja",
                    2_600 to "Llévate lo que no puedo guardar",
                ),
            )
    }

    private fun albumList(type: String?, genre: String?): List<FakeAlbum> = when (type) {
        "newest" -> albums.sortedByDescending { it.created }
        "alphabeticalByArtist" -> albums.sortedBy { it.artist.name }
        "byYear" -> albums.sortedBy { it.year }
        "byGenre" -> albums.filter { it.genre == genre }
        "starred" -> albums.filter { it.id in starredAlbums }
        // Nothing was played yet.
        "recent", "frequent" -> emptyList()
        else -> albums.sortedBy { it.name }
    }

    private fun <T> List<T>.page(offset: Int, size: Int): List<T> = drop(offset).take(size)

    private fun artistIndex(): JSONObject = JSONObject()
        .put("ignoredArticles", "The")
        .put(
            "index",
            JSONArray(
                artists.groupBy { it.name.first().toString() }.map { (letter, list) ->
                    JSONObject().put("name", letter).put("artist", JSONArray(list.map(::artistJson)))
                },
            ),
        )

    private fun artistJson(artist: FakeArtist): JSONObject = JSONObject()
        .put("id", artist.id)
        .put("name", artist.name)
        .put("coverArt", "ar-${artist.id}")
        .put("albumCount", albums.count { it.artist == artist })

    private fun albumArray(list: List<FakeAlbum>) = JSONArray(list.map(::albumJson))

    private fun albumJson(album: FakeAlbum): JSONObject {
        val tracks = songs.filter { it.album == album }
        val json = JSONObject()
            .put("id", album.id)
            .put("name", album.name)
            .put("artist", album.artist.name)
            .put("artistId", album.artist.id)
            .put("coverArt", "al-${album.id}")
            .put("songCount", tracks.size)
            .put("duration", tracks.sumOf { it.duration })
            .put("created", album.created)
            .put("year", album.year)
            .put("genre", album.genre)
        if (album.id in starredAlbums) json.put("starred", "2024-06-01T10:00:00Z")
        return json
    }

    private fun songArray(list: List<FakeSong>) = JSONArray(list.map(::songJson))

    private fun songJson(song: FakeSong): JSONObject {
        val json = JSONObject()
            .put("id", song.id)
            .put("parent", song.album.id)
            .put("isDir", false)
            .put("title", song.title)
            .put("album", song.album.name)
            .put("albumId", song.album.id)
            .put("artist", song.album.artist.name)
            .put("artistId", song.album.artist.id)
            .put("track", song.track)
            .put("discNumber", song.disc)
            .put("year", song.album.year)
            .put("genre", song.album.genre)
            .put("coverArt", "al-${song.album.id}")
            .put("size", 4_000_000)
            .put("contentType", "audio/flac")
            .put("suffix", "flac")
            .put("duration", song.duration)
            .put("bitRate", 900)
            .put("path", "${song.album.artist.name}/${song.album.name}/${song.title}.flac")
            .put("created", song.album.created)
            .put("type", "music")
            .put("comment", if (song.track == 1 && song.disc == 1) "Liner notes at https://example.org" else "")
        if (song.id in starredSongs) json.put("starred", "2024-06-01T10:00:00Z")
        return json
    }

    private fun playlistJson(playlist: FakePlaylist): JSONObject = JSONObject()
        .put("id", playlist.id)
        .put("name", playlist.name)
        .put("comment", playlist.comment)
        .put("owner", "tester")
        .put("public", false)
        .put("songCount", playlist.songs.size)
        .put("duration", playlist.songs.sumOf { songs[it].duration })
        .put("created", "2024-01-01T10:00:00Z")
        .put("changed", "2024-02-01T10:00:00Z")
        .put("coverArt", "pl-${playlist.id}")

    private fun ok(key: String? = null, value: Any? = null): MockResponse {
        val payload = envelope("ok")
        if (key != null) payload.put(key, value)
        return json(payload)
    }

    private fun notFound(): MockResponse = failed(70, "The requested data was not found.")

    private fun failed(code: Int, message: String): MockResponse = json(
        envelope("failed").put("error", JSONObject().put("code", code).put("message", message)),
    )

    private fun envelope(status: String): JSONObject = JSONObject()
        .put("status", status)
        .put("version", "1.16.1")
        .put("type", "navidrome")
        .put("serverVersion", "0.53.3 (smoke)")
        .put("openSubsonic", true)

    private fun json(payload: JSONObject): MockResponse = MockResponse()
        .setHeader("Content-Type", "application/json")
        .setBody(JSONObject().put("subsonic-response", payload).toString())

    private fun MutableList<FakeSong>.add(album: FakeAlbum, vararg titles: String) {
        titles.forEachIndexed { index, title ->
            // Two-disc albums put the second half on disc two.
            val disc = if (album.discs > 1 && index >= titles.size / 2) 2 else 1
            add(
                FakeSong(
                    id = "so-${album.id}-${index + 1}",
                    title = title,
                    album = album,
                    track = index + 1,
                    disc = disc,
                    duration = 180 + index * 7,
                ),
            )
        }
    }

    private companion object {
        const val STREAM_BYTES_PER_SECOND = 2_048L

        /** Positions in [songs]. */
        const val LOW_TIDE = 7
        const val UNDERTOW = 8
        const val SLACK_WATER = 9

        /** Three seconds of silence as 8 kHz mono 16-bit PCM. */
        val audio: ByteArray by lazy {
            val samples = ByteArray(8_000 * 2 * 3)
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + samples.size).put("WAVE".toByteArray())
                .put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
                .putInt(8_000).putInt(16_000).putShort(2).putShort(16)
                .put("data".toByteArray()).putInt(samples.size)
            header.array() + samples
        }

        const val ARTWORK_SIZE = 64

        /** One base color per cover, so pages are tinted differently. */
        val artworkColors = intArrayOf(0x1F7A8C, 0xB5446E, 0x3D5A80, 0xC8553D, 0x588157, 0x6A4C93)

        val artworks = ConcurrentHashMap<Int, ByteArray>()

        /** A square fading from the color of [id] to a darker shade; enough for decoding and tinting. */
        fun artwork(id: String): ByteArray {
            val color = artworkColors[Math.floorMod(id.hashCode(), artworkColors.size)]
            return artworks.getOrPut(color) {
                val image = BufferedImage(ARTWORK_SIZE, ARTWORK_SIZE, BufferedImage.TYPE_INT_RGB)
                for (x in 0 until ARTWORK_SIZE) {
                    for (y in 0 until ARTWORK_SIZE) {
                        val light = 1f - 0.5f * (x + y) / (2 * ARTWORK_SIZE)
                        val red = ((color shr 16 and 0xFF) * light).toInt()
                        val green = ((color shr 8 and 0xFF) * light).toInt()
                        val blue = ((color and 0xFF) * light).toInt()
                        image.setRGB(x, y, red shl 16 or (green shl 8) or blue)
                    }
                }
                ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()
            }
        }
    }
}

data class FakeArtist(val id: String, val name: String)

data class FakeAlbum(
    val id: String,
    val name: String,
    val artist: FakeArtist,
    val year: Int,
    val genre: String,
    val discs: Int,
    val created: String,
)

data class FakeSong(
    val id: String,
    val title: String,
    val album: FakeAlbum,
    val track: Int,
    val disc: Int,
    val duration: Int,
)

data class FakePlaylist(
    val id: String,
    val name: String,
    val comment: String,
    /** Indexes into the song list; a playlist may repeat a song. */
    val songs: List<Int>,
)
