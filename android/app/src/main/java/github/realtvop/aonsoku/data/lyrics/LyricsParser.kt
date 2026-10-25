package github.realtvop.aonsoku.data.lyrics

/**
 * Turns what the lyric sources return (LRC text, plain text, OpenSubsonic
 * structured lyrics) into lines to show.
 */
object LyricsParser {
    /** [mm:ss], [mm:ss.x], [mm:ss.xx], [mm:ss.xxx], or [mm:ss:xx]. */
    private val TIMESTAMP = Regex("""\[(\d+):(\d+)(?:[.:](\d+))?]""")
    private val LEADING_TIMESTAMPS = Regex("""^(?:\[\d+:\d+(?:[.:]\d+)?])+""")

    /** Tags such as [ti:…] and [ar:…], which describe the song rather than a line. */
    private val METADATA = Regex("""^\[(ti|ar|al|by|offset|re|ve|length):""")

    /** Word timestamps of enhanced LRC; lines are highlighted as a whole. */
    private val WORD_TIMESTAMP = Regex("""<\d+:\d+(?:[.:]\d+)?>""")

    private const val SYNC_PROBE_LINES = 20

    /** How long the last line lasts when the length of the song is unknown. */
    private const val LAST_LINE_MS = 5_000L

    private data class Timed(val time: Long, val text: String)

    /** Whether [text] is LRC, judging by its first lines. */
    fun isSynced(text: String): Boolean = text.trim().lineSequence()
        .take(SYNC_PROBE_LINES)
        .any { LEADING_TIMESTAMPS.containsMatchIn(it.trim()) }

    /**
     * Picks what to show, best first: synced structured lyrics, unsynced
     * structured lyrics, LRC text, plain text. The second structured track is
     * the translation of the first.
     */
    fun resolve(data: LyricsData, showTranslation: Boolean, durationMs: Long?): Lyrics? {
        val tracks = data.structured.filter { track -> track.line.any { it.value.isNotBlank() } }
        val primary = tracks.firstOrNull()
        if (primary != null) {
            val translation = tracks.getOrNull(1)
            if (primary.synced) {
                val lines = fromStructured(primary, translation, durationMs)
                return Lyrics.Synced(lines.withTranslation(showTranslation))
            }
            return Lyrics.Plain(
                lines = primary.line.map { it.value },
                translations = if (showTranslation) translation?.line.orEmpty().map { it.value } else emptyList(),
            )
        }

        val text = data.text?.takeIf { it.value.isNotBlank() } ?: return null
        if (isSynced(text.value)) {
            val lines = parseLrc(text.value, durationMs, text.romaji)
            if (lines.isEmpty()) return null
            return Lyrics.Synced(
                lines = lines.withTranslation(showTranslation),
                hasRoman = lines.any { it.roman.isNotEmpty() },
            )
        }
        return plainLines(text.value).takeIf { it.isNotEmpty() }?.let { Lyrics.Plain(it) }
    }

    private fun List<LyricLine>.withTranslation(show: Boolean): List<LyricLine> =
        if (show) this else map { it.copy(translation = "") }

    /**
     * Parses LRC. Two lines in a row with the same timestamp are a line and
     * its translation; [romaji] is a second LRC track matched by timestamp.
     */
    fun parseLrc(text: String, durationMs: Long? = null, romaji: String? = null): List<LyricLine> {
        val timed = timedLines(text)
        val roman = romaji?.takeIf { it.isNotBlank() }
            ?.let { track -> timedLines(track).filter { it.text.isNotEmpty() }.associate { it.time to it.text } }
            .orEmpty()

        val main = ArrayList<Timed>(timed.size)
        val translations = HashMap<Int, String>()
        var index = 0
        while (index < timed.size) {
            val line = timed[index]
            main += line
            if (timed.getOrNull(index + 1)?.time == line.time) {
                translations[main.lastIndex] = timed[index + 1].text
                index += 2
            } else {
                index += 1
            }
        }

        return main.mapIndexed { position, line ->
            LyricLine(
                startMs = line.time,
                endMs = endOf(line.time, main.getOrNull(position + 1)?.time, durationMs),
                text = line.text,
                translation = translations[position].orEmpty(),
                roman = roman[line.time].orEmpty(),
            )
        }
    }

    /**
     * Converts a synced structured track. Without a [translation] track, lines
     * sharing a start are read like in LRC: the last two of them are a line
     * and its translation.
     */
    fun fromStructured(
        primary: StructuredLyrics,
        translation: StructuredLyrics? = null,
        durationMs: Long? = null,
    ): List<LyricLine> {
        var lines = primary.line
        var inline: Map<Int, String> = emptyMap()
        val external = translation?.line.orEmpty()
            .filter { it.start != null && it.value.isNotEmpty() }
            .associate { (it.start ?: 0L) to it.value }

        if (translation == null) {
            val main = ArrayList<StructuredLine>(lines.size)
            val paired = HashMap<Int, String>()
            var index = 0
            while (index < lines.size) {
                var last = index
                while (last + 1 < lines.size && lines[last + 1].start == lines[index].start) last++
                if (last > index) {
                    for (standalone in index until last - 1) main += lines[standalone]
                    main += lines[last - 1]
                    paired[main.lastIndex] = lines[last].value
                } else {
                    main += lines[index]
                }
                index = last + 1
            }
            if (paired.isNotEmpty()) {
                lines = main
                inline = paired
            }
        }

        return lines.mapIndexed { position, line ->
            val start = line.start ?: 0L
            LyricLine(
                startMs = start,
                endMs = endOf(start, lines.getOrNull(position + 1)?.let { it.start ?: (start + LAST_LINE_MS) }, durationMs),
                text = line.value,
                translation = inline[position] ?: external[start].orEmpty(),
            )
        }
    }

    /** The lines of plain lyrics, without LRC tags and blank lines. */
    fun plainLines(text: String): List<String> = text.lineSequence()
        .map { it.trim() }
        .filterNot { METADATA.containsMatchIn(it) }
        .map { it.replace(LEADING_TIMESTAMPS, "").trim() }
        .filter { it.isNotEmpty() }
        .toList()

    /** A line lasts until the next one, or until the song (or a few seconds) ends. */
    private fun endOf(start: Long, next: Long?, durationMs: Long?): Long =
        (next ?: durationMs ?: (start + LAST_LINE_MS)).coerceAtLeast(start)

    /** The timed lines of [text] in order; a line with several timestamps is repeated. */
    private fun timedLines(text: String): List<Timed> {
        val lines = ArrayList<Timed>()
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            val stamps = LEADING_TIMESTAMPS.find(line) ?: continue
            val content = line.substring(stamps.value.length).replace(WORD_TIMESTAMP, "").trim()
            for (stamp in TIMESTAMP.findAll(stamps.value)) lines += Timed(stamp.toMillis(), content)
        }
        return lines.sortedBy { it.time }
    }

    private fun MatchResult.toMillis(): Long {
        val minutes = groupValues[1].toLongOrNull() ?: 0L
        val seconds = groupValues[2].toLongOrNull() ?: 0L
        // One digit is tenths, two are hundredths, three are milliseconds.
        val fraction = groupValues[3].take(3).padEnd(3, '0').toLongOrNull() ?: 0L
        return minutes * 60_000 + seconds * 1_000 + fraction
    }
}
