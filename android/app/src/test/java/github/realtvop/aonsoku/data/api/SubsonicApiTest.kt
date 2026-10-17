package github.realtvop.aonsoku.data.api

import github.realtvop.aonsoku.plugins.bridge.ServerCredentials
import kotlinx.coroutines.runBlocking
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException

class SubsonicApiTest {
    private val requests = mutableListOf<Request>()
    private var unreachableCalls = 0

    private fun credentials(serverType: String = "navidrome", authType: String = "token") =
        ServerCredentials(
            serverUrl = "https://music.example/base/",
            username = "ann",
            password = "secret-token",
            authType = authType,
            protocolVersion = "1.16.1",
            serverType = serverType,
            fallbackUrl = null,
        )

    private fun api(
        credentials: ServerCredentials? = credentials(),
        status: Int = 200,
        headers: Map<String, String> = emptyMap(),
        failure: IOException? = null,
        body: () -> String,
    ): SubsonicApi {
        val interceptor = Interceptor { chain ->
            requests += chain.request()
            failure?.let { throw it }
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(status)
                .message("test")
                .apply { headers.forEach { (name, value) -> header(name, value) } }
                .body(body().toResponseBody("application/json".toMediaType()))
                .build()
        }
        return SubsonicApi(
            credentials = { credentials },
            client = OkHttpClient.Builder().addInterceptor(interceptor).build(),
            onUnreachable = { unreachableCalls++ },
        )
    }

    private fun ok(payload: String = "") =
        """{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.53.3","openSubsonic":true${if (payload.isEmpty()) "" else ",$payload"}}}"""

    @Test
    fun buildsAuthenticatedRestUrls() = runBlocking {
        val info = api { ok() }.ping()
        val url = requests.single().url

        assertEquals("https://music.example/base/rest/ping.view", url.toString().substringBefore("?"))
        assertEquals("ann", url.queryParameter("u"))
        assertEquals("secret-token", url.queryParameter("t"))
        assertEquals("40n50kuPl4y3r", url.queryParameter("s"))
        assertEquals("1.16.1", url.queryParameter("v"))
        assertEquals("Aonsoku", url.queryParameter("c"))
        assertEquals("json", url.queryParameter("f"))
        assertNull(url.queryParameter("p"))
        assertEquals("navidrome", info.type)
        assertEquals("0.53.3", info.serverVersion)
        assertTrue(info.openSubsonic)
    }

    @Test
    fun usesPasswordAuthenticationWhenStored() = runBlocking {
        api(credentials(authType = "password")) { ok() }.ping()
        val url = requests.single().url

        assertEquals("secret-token", url.queryParameter("p"))
        assertNull(url.queryParameter("t"))
    }

    @Test
    fun readsAlbumListsAndTheTotalCountHeader() = runBlocking {
        val page = api(headers = mapOf("x-total-count" to "321")) {
            ok(""""albumList2":{"album":[{"id":"al-1","name":"One","artist":"A","songCount":9,"duration":1800,"unknownField":true},{"id":"al-2","name":"Two"}]}""")
        }.getAlbumList(type = "byYear", size = 50, offset = 100, fromYear = 1, toYear = 2026)
        val url = requests.single().url

        assertEquals(listOf("al-1", "al-2"), page.albums.map { it.id })
        assertEquals(9, page.albums.first().songCount)
        assertEquals(321, page.total)
        assertEquals("byYear", url.queryParameter("type"))
        assertEquals("50", url.queryParameter("size"))
        assertEquals("100", url.queryParameter("offset"))
        assertEquals("1", url.queryParameter("fromYear"))
        assertEquals("2026", url.queryParameter("toYear"))
        assertNull(url.queryParameter("genre"))
    }

    @Test
    fun acceptsMissingAndCollapsedLists() = runBlocking {
        assertTrue(api { ok(""""albumList2":{}""") }.getAlbumList("newest").albums.isEmpty())
        assertTrue(api { ok() }.getPlaylists().isEmpty())

        val single = api {
            ok(""""playlists":{"playlist":{"id":"pl-1","name":"Solo","public":true}}""")
        }.getPlaylists()

        assertEquals("pl-1", single.single().id)
        assertTrue(single.single().isPublic)
    }

    @Test
    fun skipsListEntriesThatCannotBeDecoded() = runBlocking {
        val songs = api {
            ok(""""topSongs":{"song":[{"title":"missing id"},{"id":"s-1","title":"Good","duration":"201"}]}""")
        }.getTopSongs("Artist")

        assertEquals("s-1", songs.single().id)
        assertEquals(201, songs.single().duration)
    }

    @Test
    fun flattensAndSortsArtistIndexes() = runBlocking {
        val artists = api {
            ok(""""artists":{"index":[{"name":"Z","artist":[{"id":"1","name":"zed"}]},{"name":"A","artist":[{"id":"2","name":"Alpha"},{"id":"3","name":"beta"}]}]}""")
        }.getArtists()

        assertEquals(listOf("Alpha", "beta", "zed"), artists.map { it.name })
    }

    @Test
    fun searchListsEverythingWithTheServerSpecificEmptyQuery() = runBlocking {
        api(credentials("navidrome")) { ok(""""searchResult3":{}""") }.search("")
        api(credentials("subsonic")) { ok(""""searchResult3":{}""") }.search("")
        api { ok(""""searchResult3":{"song":[{"id":"s"}]}""") }
            .search("hello world", songCount = 5, songOffset = 10)

        assertEquals("\"\"", requests[0].url.queryParameter("query"))
        assertEquals("", requests[1].url.queryParameter("query"))
        assertEquals("hello world", requests[2].url.queryParameter("query"))
        assertEquals("5", requests[2].url.queryParameter("songCount"))
        assertEquals("10", requests[2].url.queryParameter("songOffset"))
    }

    @Test
    fun sendsRepeatedParametersForPlaylistEdits() = runBlocking {
        api { ok() }.updatePlaylist(
            playlistId = "pl-1",
            name = "Renamed",
            isPublic = false,
            songIdsToAdd = listOf("a", "b"),
            songIndexesToRemove = listOf(3, 1),
        )
        val url = requests.single().url

        assertEquals("pl-1", url.queryParameter("playlistId"))
        assertEquals("Renamed", url.queryParameter("name"))
        assertEquals("false", url.queryParameter("public"))
        assertNull(url.queryParameter("comment"))
        assertEquals(listOf("a", "b"), url.queryParameterValues("songIdToAdd"))
        assertEquals(listOf("3", "1"), url.queryParameterValues("songIndexToRemove"))
    }

    @Test
    fun createsRadiosWithPost() = runBlocking {
        api { ok() }.createRadio("Jazz", "https://stream.example/jazz", "https://example.com")
        val request = requests.single()

        assertEquals("POST", request.method)
        assertEquals("https://stream.example/jazz", request.url.queryParameter("streamUrl"))
        assertEquals("https://example.com", request.url.queryParameter("homepageUrl"))
    }

    @Test
    fun mapsServerFailures() = runBlocking {
        val failed = { code: Int ->
            """{"subsonic-response":{"status":"failed","error":{"code":$code,"message":"nope"}}}"""
        }
        try {
            api { failed(40) }.ping()
            fail("expected an authentication failure")
        } catch (error: ApiException.AuthFailed) {
            assertEquals("nope", error.message)
        }
        try {
            api { failed(70) }.getAlbum("missing")
            fail("expected a server failure")
        } catch (error: ApiException.Server) {
            assertEquals(70, error.code)
        }
        assertEquals(0, unreachableCalls)
    }

    @Test
    fun mapsTransportAndFormatFailures() = runBlocking {
        try {
            api(status = 502) { "bad gateway" }.ping()
            fail("expected an HTTP failure")
        } catch (error: ApiException.Http) {
            assertEquals(502, error.status)
        }
        try {
            api { "<html>" }.ping()
            fail("expected a parse failure")
        } catch (_: ApiException.Parse) {
        }
        try {
            api { """{"other":1}""" }.ping()
            fail("expected a parse failure")
        } catch (_: ApiException.Parse) {
        }
        assertEquals(0, unreachableCalls)

        try {
            api(failure = IOException("no route")) { "" }.ping()
            fail("expected a network failure")
        } catch (_: ApiException.NetworkUnreachable) {
        }
        assertEquals(1, unreachableCalls)
    }

    @Test
    fun refusesToCallWithoutCredentials() = runBlocking {
        try {
            api(credentials = null) { ok() }.ping()
            fail("expected a missing session failure")
        } catch (_: ApiException.NotSignedIn) {
        }
        assertTrue(requests.isEmpty())
        assertNull(api(credentials = null) { ok() }.coverArtUrl("x"))
        assertFalse(api { ok() }.coverArtUrl("cover 1", 300).orEmpty().contains(" "))
    }
}
