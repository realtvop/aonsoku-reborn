package github.realtvop.aonsoku.plugins.data

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeLibraryCodecTest {
    @Test fun repeatedSongIdsKeepOrderAndDuplicates() {
        assertEquals("createPlaylist.view?playlistId=p&songId=b&songId=a&songId=b", NativeLibraryCodec.requestPath("createPlaylist", listOf("playlistId" to "p", "songId" to "b", "songId" to "a", "songId" to "b")))
    }
    @Test fun queryValuesCannotInjectParameters() {
        assertEquals("star.view?id=a%26albumId%3Db%2F%E6%AD%8C", NativeLibraryCodec.requestPath("star", listOf("id" to "a&albumId=b/歌")))
    }
    @Test fun emptyQueryKeepsNormalEndpoint() { assertEquals("getPlaylists.view", NativeLibraryCodec.requestPath("getPlaylists", emptyList())) }
    @Test fun songDecodingPreservesNativePlaybackMetadata() {
        val song = NativeLibraryCodec.parseSong(JSONObject("""{"id":"s","title":"Song","duration":123,"albumId":"a","starred":"2026-10-11T00:00:00Z","replayGain":{"trackGain":-4}}"""))!!
        assertEquals("a", song.albumId)
        assertEquals(123, song.duration)
        assertNotNull(song.starredAt)
        assertEquals(-4, JSONObject(song.replayGainJson!!).getInt("trackGain"))
    }
    @Test fun malformedRowsAreIgnored() { assertNull(NativeLibraryCodec.parseSong(JSONObject("""{"id":"s"}"""))); assertNull(NativeLibraryCodec.parseSong(null)) }
}
