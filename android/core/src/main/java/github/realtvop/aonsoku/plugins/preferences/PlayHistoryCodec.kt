package github.realtvop.aonsoku.plugins.preferences

import org.json.JSONArray

object PlayHistoryCodec {
    fun decode(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()

        return try {
            val json = JSONArray(raw)
            buildList {
                for (index in 0 until json.length()) {
                    add(json.optString(index))
                }
            }.filter { it.isNotBlank() }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun encode(history: List<String>): String = JSONArray(history).toString()

    fun add(raw: String?, song: String, maxSize: Int): String {
        val clampedSize = maxSize.coerceAtLeast(0)
        if (clampedSize == 0) return encode(emptyList())

        val next = mutableListOf(song)
        next.addAll(decode(raw))

        return encode(next.take(clampedSize))
    }
}
