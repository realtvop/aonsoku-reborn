package github.realtvop.aonsoku.plugins.audio

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeAudioSourceParserTest {

    @Test
    fun parseSourceWithValidStream() {
        val json = JSONObject()
        json.put("kind", "stream")
        json.put("url", "https://example.com/song.mp3")
        json.put("songId", "song-123")

        val result = NativeAudioSourceParser.parseSource(json)
        assertEquals("stream", result?.kind)
        assertEquals("https://example.com/song.mp3", result?.url)
        assertEquals("song-123", result?.songId)
        assertNull(result?.uri)
        assertNull(result?.radioId)
    }

    @Test
    fun parseSourceWithValidNativeFile() {
        val json = JSONObject()
        json.put("kind", "native-file")
        json.put("uri", "content://media/external/audio/media/1")
        json.put("songId", "song-456")

        val result = NativeAudioSourceParser.parseSource(json)
        assertEquals("native-file", result?.kind)
        assertEquals("content://media/external/audio/media/1", result?.uri)
        assertEquals("song-456", result?.songId)
        assertNull(result?.url)
        assertNull(result?.radioId)
    }

    @Test
    fun parseSourceWithRadioKind() {
        val json = JSONObject()
        json.put("kind", "radio")
        json.put("url", "https://radio.example.com/stream")
        json.put("radioId", "radio-789")

        val result = NativeAudioSourceParser.parseSource(json)
        assertEquals("radio", result?.kind)
        assertEquals("https://radio.example.com/stream", result?.url)
        assertEquals("radio-789", result?.radioId)
        assertNull(result?.uri)
        assertNull(result?.songId)
    }

    @Test
    fun parseSourceWithBlobKind() {
        val json = JSONObject()
        json.put("kind", "blob")
        json.put("url", "blob:http://example.com/uuid")
        json.put("songId", "song-blob")

        val result = NativeAudioSourceParser.parseSource(json)
        assertEquals("blob", result?.kind)
        assertEquals("blob:http://example.com/uuid", result?.url)
        assertEquals("song-blob", result?.songId)
        assertNull(result?.uri)
        assertNull(result?.radioId)
    }

    @Test
    fun parseSourceWithNull() {
        assertNull(NativeAudioSourceParser.parseSource(null))
    }

    @Test
    fun parseMetadataWithValidInput() {
        val json = JSONObject()
        json.put("title", "Song Title")
        json.put("artist", "Artist Name")
        json.put("album", "Album Title")
        json.put("duration", 240.5)
        json.put("artworkUrl", "https://example.com/cover.jpg")

        val result = NativeAudioSourceParser.parseMetadata(json)
        assertEquals("Song Title", result?.title)
        assertEquals("Artist Name", result?.artist)
        assertEquals("Album Title", result?.album)
        assertEquals(240.5, result?.duration ?: 0.0, 0.001)
        assertEquals("https://example.com/cover.jpg", result?.artworkUrl)
    }

    @Test
    fun parseMetadataWithNull() {
        assertNull(NativeAudioSourceParser.parseMetadata(null))
    }
}
