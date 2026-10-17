package github.realtvop.aonsoku.plugins.preferences

import org.junit.Assert.assertEquals
import org.junit.Test

class PlayHistoryCodecTest {
    @Test
    fun decodeReturnsEmptyListForMissingOrCorruptJson() {
        assertEquals(emptyList<String>(), PlayHistoryCodec.decode(null))
        assertEquals(emptyList<String>(), PlayHistoryCodec.decode("not-json"))
    }

    @Test
    fun addPrependsNewestSongAndTrimsToMaxSize() {
        val existing = PlayHistoryCodec.encode(listOf("song-2", "song-1"))
        val updated = PlayHistoryCodec.add(
            raw = existing,
            song = "song-3",
            maxSize = 2,
        )

        assertEquals(listOf("song-3", "song-2"), PlayHistoryCodec.decode(updated))
    }

    @Test
    fun addWithZeroMaxSizeClearsHistory() {
        val existing = PlayHistoryCodec.encode(listOf("song-2", "song-1"))

        assertEquals(
            emptyList<String>(),
            PlayHistoryCodec.decode(
                PlayHistoryCodec.add(existing, "song-3", maxSize = 0),
            ),
        )
    }
}
