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
    fun cacheFileNamesLeadBackToTheirSongs() {
        for (songId in listOf("abc", ">>>", "song?id=123", "歌曲 1", "a")) {
            assertEquals(songId, AudioCacheUtils.songId(AudioCacheUtils.cacheId(songId)))
        }
        // Names this app would not have written.
        assertEquals(null, AudioCacheUtils.songId(""))
        assertEquals(null, AudioCacheUtils.songId("not base64!"))
        assertEquals(null, AudioCacheUtils.songId("YWJj=="))
    }

    @Test
    fun cachedFilesAreFoundAndDeletedInEveryDirectory() {
        val root = java.nio.file.Files.createTempDirectory("audio-cache").toFile()
        try {
            val primary = java.io.File(root, "primary").apply { mkdirs() }
            val secondary = java.io.File(root, "secondary").apply { mkdirs() }
            val missing = java.io.File(root, "missing")
            val directories = listOf(missing, primary, secondary)
            val cacheId = AudioCacheUtils.cacheId("song")
            val copy = java.io.File(secondary, "$cacheId.opus").apply { writeText("audio") }
            val note = java.io.File(secondary, "$cacheId.json").apply { writeText("{}") }
            val other = java.io.File(primary, "${AudioCacheUtils.cacheId("other")}.mp3").apply { writeText("audio") }

            assertEquals(copy, AudioCacheUtils.findFile(directories, "song"))
            assertEquals(null, AudioCacheUtils.findFile(directories, "unknown"))
            assertEquals(note, AudioCacheUtils.metadataFile(secondary, "song"))

            assertEquals(true, AudioCacheUtils.deleteFiles(directories, "song"))
            assertEquals(false, copy.exists() || note.exists())
            assertEquals(true, other.exists())
            assertEquals(false, AudioCacheUtils.deleteFiles(directories, "song"))
        } finally {
            root.deleteRecursively()
        }
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
