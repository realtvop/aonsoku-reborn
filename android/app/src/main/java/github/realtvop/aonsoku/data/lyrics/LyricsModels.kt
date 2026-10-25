package github.realtvop.aonsoku.data.lyrics

import kotlinx.serialization.Serializable
import kotlin.math.roundToInt

/** One line of lyrics and the stretch of the song it belongs to. */
data class LyricLine(
    val startMs: Long,
    val endMs: Long,
    val text: String,
    val translation: String = "",
    /** Romanization (romaji, romaja) of [text]. */
    val roman: String = "",
)

/** Lyrics ready to show. */
sealed interface Lyrics {
    /** Timed lines, ordered by start. */
    data class Synced(val lines: List<LyricLine>, val hasRoman: Boolean = false) : Lyrics

    /** Untimed text; [translations] line up with [lines] by index. */
    data class Plain(val lines: List<String>, val translations: List<String> = emptyList()) : Lyrics
}

/** One track of OpenSubsonic structured lyrics (`getLyricsBySongId`). */
@Serializable
data class StructuredLyrics(
    val lang: String = "",
    val synced: Boolean = false,
    val line: List<StructuredLine> = emptyList(),
)

@Serializable
data class StructuredLine(
    /** Start in milliseconds; absent in unsynced tracks. */
    val start: Long? = null,
    val value: String = "",
)

/** Lyrics as text: LRC when the lines carry timestamps, plain otherwise. */
@Serializable
data class LyricsText(
    val value: String,
    /** A romanization track in LRC, matched to [value] by timestamp. */
    val romaji: String? = null,
)

/** What the sources know about a song, before it is turned into [Lyrics]. */
data class LyricsData(
    val structured: List<StructuredLyrics> = emptyList(),
    val text: LyricsText? = null,
)

/** What lyrics are looked up and remembered by. */
data class LyricsSong(
    val id: String,
    val artist: String,
    val title: String,
    val album: String = "",
    val durationSeconds: Double = 0.0,
    val path: String = "",
) {
    /**
     * Identifies the song in the per-song lyric choices. The web app wrote
     * the same key, so choices made there keep applying.
     */
    val key: String get() = listOf(path, artist, title, album).joinToString(KEY_SEPARATOR)

    val durationMs: Long? get() = durationSeconds.takeIf { it > 0 }?.let { (it * 1000).toLong() }

    /** Whole seconds, the way lyric services expect the length of a song. */
    val durationParam: String? get() = durationSeconds.takeIf { it > 0 }?.roundToInt()?.toString()

    private companion object {
        const val KEY_SEPARATOR = "\u001f"
    }
}

/** An entry a custom lyrics server offers for a song. */
@Serializable
data class LyricsCandidate(
    val id: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val lyrics: String? = null,
    val romaji: String? = null,
) {
    val hasRomaji: Boolean get() = !romaji.isNullOrBlank()

    /** Identifies the entry among the ones a search returned; [index] is its place there. */
    fun key(index: Int): String =
        id?.takeIf { it.isNotEmpty() } ?: "$index:${artist.orEmpty()}:${title.orEmpty()}"
}
