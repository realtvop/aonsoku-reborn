package github.realtvop.aonsoku.plugins.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SubsonicHttpClientTest {
    private val credentials = ServerCredentials(
        serverUrl = "https://music.example",
        username = "alice",
        password = "enc:736563726574",
        authType = "password",
        protocolVersion = "1.16.0",
        serverType = "navidrome",
        fallbackUrl = null,
    )

    @Test
    fun buildUrlAppendsRestPathAndAuthQuery() {
        val url = SubsonicHttpClient().buildUrl(
            baseUrl = "https://music.example/",
            path = "/getAlbum",
            credentials = credentials,
            extraQuery = mapOf("id" to "album 1"),
        )

        assertEquals("https", url.protocol)
        assertEquals("music.example", url.host)
        assertEquals("/rest/getAlbum", url.path)
        assertTrue(url.query.contains("u=alice"))
        assertTrue(url.query.contains("p=enc%3A736563726574"))
        assertTrue(url.query.contains("id=album+1"))
    }

    @Test
    fun buildUrlPreservesExistingPathQuery() {
        val url = SubsonicHttpClient().buildUrl(
            baseUrl = "https://music.example",
            path = "updatePlaylist?playlistId=1",
            credentials = credentials,
            extraQuery = mapOf("name" to "Road Songs"),
        )

        assertEquals("/rest/updatePlaylist", url.path)
        assertTrue(url.query.startsWith("playlistId=1&"))
        assertTrue(url.query.contains("name=Road+Songs"))
    }
}
