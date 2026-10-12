package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioCacheUtilsTest {

    @Test
    fun testCacheIdGeneration() {
        // "abc" in Base64 is "YWJj"
        assertEquals("YWJj", AudioCacheUtils.cacheId("abc"))

        // Special characters to check replacement rules
        // "song?id=123" in base64: c29uZz9pZD0xMjM=
        // With padding removed: c29uZz9pZD0xMjM
        // If there are "+" or "/", they should be replaced with "-" and "_"
        // e.g. ">>>" in UTF-8 bytes: [0x3E, 0x3E, 0x3E]
        // Base64 of ">>>" is "Pj4+" -> should become "Pj4-"
        assertEquals("Pj4-", AudioCacheUtils.cacheId(">>>"))
    }

    @Test
    fun testFileExtensionMapping() {
        assertEquals("mp3", AudioCacheUtils.fileExtension("audio/mpeg"))
        assertEquals("mp3", AudioCacheUtils.fileExtension("audio/mp3; charset=utf-8"))
        assertEquals("flac", AudioCacheUtils.fileExtension("audio/flac"))
        assertEquals("m4a", AudioCacheUtils.fileExtension("audio/m4a"))
        assertEquals("ogg", AudioCacheUtils.fileExtension("application/ogg"))
        assertEquals("audio", AudioCacheUtils.fileExtension("unknown/format"))
    }
}
