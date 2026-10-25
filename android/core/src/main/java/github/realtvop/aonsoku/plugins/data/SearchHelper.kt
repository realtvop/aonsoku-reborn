package github.realtvop.aonsoku.plugins.data
import java.text.Normalizer
object SearchHelper {
    fun normalize(text: String) = Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{M}"), "").lowercase()
    fun tokenize(query: String) = normalize(query).split(Regex("\\s+")).filter { it.isNotEmpty() }
    fun buildCondition(query: String, columns: List<String>): String? {
        val tokens = tokenize(query)
        if (tokens.isEmpty()) return null
        return tokens.joinToString(" AND ") { token ->
            columns.joinToString(" OR ") { col ->
                "LOWER($col) LIKE '%$token%'"
            }.let { "($it)" }
        }
    }
}
