package github.realtvop.aonsoku.utils

data class LyricLine(
    val timeSeconds: Double,
    val text: String,
)

object LrcParser {
    private val TIME_TAG_REGEX = Regex("""\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\]""")

    fun parse(lrcContent: String?): List<LyricLine> {
        if (lrcContent.isNullOrBlank()) return emptyList()

        val lines = mutableListOf<LyricLine>()
        for (rawLine in lrcContent.lines()) {
            val trimmed = rawLine.trim()
            if (trimmed.isEmpty()) continue

            val match = TIME_TAG_REGEX.find(trimmed)
            if (match != null) {
                val minutes = match.groupValues[1].toDoubleOrNull() ?: 0.0
                val seconds = match.groupValues[2].toDoubleOrNull() ?: 0.0
                val millisString = match.groupValues.getOrNull(3) ?: "0"
                val millis = if (millisString.length == 2) {
                    (millisString.toDoubleOrNull() ?: 0.0) / 100.0
                } else {
                    (millisString.toDoubleOrNull() ?: 0.0) / 1000.0
                }
                val totalSeconds = minutes * 60.0 + seconds + millis
                val text = trimmed.substring(match.range.last + 1).trim()
                if (text.isNotEmpty()) {
                    lines.add(LyricLine(timeSeconds = totalSeconds, text = text))
                }
            } else if (!trimmed.startsWith("[")) {
                // Plain line without timestamp
                lines.add(LyricLine(timeSeconds = -1.0, text = trimmed))
            }
        }
        return lines.sortedBy { it.timeSeconds }
    }
}
