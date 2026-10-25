package github.realtvop.aonsoku.data.lyrics

import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LyricsSourcesTest {
    private val requests = mutableListOf<Request>()

    private val song = LyricsSong(
        id = "so-1",
        artist = "Blue Meridian",
        title = "Low Tide",
        album = "Tidal Hours",
        durationSeconds = 187.4,
        path = "Blue Meridian/Tidal Hours/Low Tide.flac",
    )

    private val server = CustomLyricsServer("https://lyrics.example/find?token=abc", password = "s3cret")

    private fun sources(
        status: Int = 200,
        contentType: String = "application/json",
        body: String,
    ): LyricsSources {
        val client = OkHttpClient.Builder()
            .addInterceptor(
                Interceptor { chain ->
                    requests += chain.request()
                    Response.Builder()
                        .request(chain.request())
                        .protocol(Protocol.HTTP_1_1)
                        .code(status)
                        .message("status")
                        .header("Content-Type", contentType)
                        .body(body.toResponseBody(contentType.toMediaType()))
                        .build()
                },
            )
            .build()
        return LyricsSources(client, clientName = "Aonsoku test")
    }

    @Test
    fun lrcLibIsAskedWithTheSongAndPrefersSyncedLyrics() = runBlocking {
        val found = sources(
            body = """{"id": 7, "plainLyrics": "plain", "syncedLyrics": "[00:01.00]synced\r\n[00:02.00]lines\n"}""",
        ).fromLrcLib(song)

        assertEquals("[00:01.00]synced\n[00:02.00]lines", found?.value)
        val request = requests.single()
        assertEquals("lrclib.net", request.url.host)
        assertEquals("Blue Meridian", request.url.queryParameter("artist_name"))
        assertEquals("Low Tide", request.url.queryParameter("track_name"))
        assertEquals("Tidal Hours", request.url.queryParameter("album_name"))
        assertEquals("187", request.url.queryParameter("duration"))
        assertEquals("Aonsoku test", request.header("Lrclib-Client"))
    }

    @Test
    fun lrcLibFallsBackToPlainLyricsAndToNothing() = runBlocking {
        val plain = sources(body = """{"plainLyrics": "just words", "syncedLyrics": null}""").fromLrcLib(song)
        assertEquals("just words", plain?.value)

        val unknown = sources(
            status = 404,
            body = """{"code": 404, "name": "TrackNotFound", "message": "Failed to find specified track"}""",
        ).fromLrcLib(song)
        assertNull(unknown)
    }

    @Test
    fun lrcLibCanBeAskedForAnotherArtist() = runBlocking {
        sources(body = "{}").fromLrcLib(song, artist = "Cartoon")
        assertEquals("Cartoon", requests.single().url.queryParameter("artist_name"))
    }

    @Test
    fun customServerIsAskedWithEverythingKnownAboutTheSong() = runBlocking {
        val found = sources(
            body = """[{"id": "a", "lyrics": "[00:01.00]first"}, {"id": "b", "lyrics": "[00:01.00]second"}]""",
        ).fromCustomServer(song, server)

        assertEquals("[00:01.00]first", found?.value)
        val request = requests.single()
        // What the configured address already carries stays.
        assertEquals("abc", request.url.queryParameter("token"))
        assertEquals("Low Tide", request.url.queryParameter("title"))
        assertEquals("Blue Meridian", request.url.queryParameter("artist"))
        assertEquals("Tidal Hours", request.url.queryParameter("album"))
        assertEquals("187", request.url.queryParameter("duration"))
        assertEquals(song.path, request.url.queryParameter("path"))
        assertEquals("0", request.url.queryParameter("offset"))
        assertEquals("10", request.url.queryParameter("limit"))
        assertEquals("s3cret", request.header("Authorization"))
    }

    @Test
    fun customServerAnswerFollowsTheChosenEntry() = runBlocking {
        val body = """
            [
              {"id": "a", "lyrics": "[00:01.00]first"},
              {"lyrics": "   "},
              {"id": "b", "lyrics": "[00:01.00]second", "romaji": "[00:01.00]ni\r\n"}
            ]
        """.trimIndent()
        val chosen = sources(body = body).fromCustomServer(song, server, selectedKey = "b")
        assertEquals("[00:01.00]second", chosen?.value)
        assertEquals("[00:01.00]ni", chosen?.romaji)

        // An entry that is gone falls back to the first one.
        val gone = sources(body = body).fromCustomServer(song, server, selectedKey = "zzz")
        assertEquals("[00:01.00]first", gone?.value)
        assertNull(gone?.romaji)
    }

    @Test
    fun customServerMayAnswerWithPlainText() = runBlocking {
        val found = sources(contentType = "text/plain; charset=utf-8", body = " [00:01.00]text\r\n").fromCustomServer(
            song,
            CustomLyricsServer("https://lyrics.example/find"),
        )
        assertEquals("[00:01.00]text", found?.value)
        assertNull(requests.single().header("Authorization"))
    }

    @Test
    fun customServerErrorsAndEmptyAnswersAreNothing() = runBlocking {
        assertNull(sources(status = 500, body = "[]").fromCustomServer(song, server))
        assertNull(sources(body = "[]").fromCustomServer(song, server))
        assertNull(sources(body = """{"not": "a list"}""").fromCustomServer(song, server))
        assertNull(sources(body = "x").fromCustomServer(song, CustomLyricsServer("not a url")))
    }

    @Test
    fun candidatesAreSearchedByTitleAndArtistOnly() = runBlocking {
        val candidates = sources(
            body = """
                [
                  {"id": 12, "title": "Low Tide", "artist": "Blue Meridian", "lyrics": "la", "romaji": "ra"},
                  {"title": "Low Tide (Live)", "lyrics": "la la"},
                  {"title": "No lyrics", "lyrics": ""}
                ]
            """.trimIndent(),
        ).candidates(server, title = " Low Tide ", artist = "")

        assertEquals(2, candidates.size)
        // An id identifies an entry; without one its place and names do.
        assertEquals("12", candidates[0].key(0))
        assertEquals("1::Low Tide (Live)", candidates[1].key(1))
        assertTrue(candidates[0].hasRomaji)

        val request = requests.single()
        assertEquals("Low Tide", request.url.queryParameter("title"))
        assertNull(request.url.queryParameter("artist"))
        assertNull(request.url.queryParameter("limit"))
    }

    @Test
    fun candidatesNeedAJsonAnswer() = runBlocking {
        assertTrue(sources(contentType = "text/plain", body = "lyrics").candidates(server, "Low Tide", null).isEmpty())
        assertTrue(sources(status = 401, body = "[]").candidates(server, "Low Tide", null).isEmpty())
    }
}
