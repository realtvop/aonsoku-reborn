package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class ScrobbleFileStore(context: Context) : ScrobbleEntryStore {
    private val file: File = File(
        context.filesDir,
        SCROBBLE_FILE_NAME,
    )

    override fun save(entries: List<ScrobbleEntry>) {
        try {
            val array = JSONArray()
            for (entry in entries) {
                array.put(JSONObject().apply {
                    put("songId", entry.songId)
                    put("playedDurationMs", entry.playedDurationMs)
                    put("timestamp", entry.timestamp)
                })
            }
            file.writeText(array.toString(), Charsets.UTF_8)
        } catch (_: Exception) {
        }
    }

    override fun load(): List<ScrobbleEntry> {
        if (!file.exists()) return emptyList()
        return try {
            val text = file.readText(Charsets.UTF_8)
            val array = JSONArray(text)
            val result = mutableListOf<ScrobbleEntry>()
            for (i in 0 until array.length()) {
                val obj = array.getJSONObject(i)
                result.add(
                    ScrobbleEntry(
                        songId = obj.getString("songId"),
                        playedDurationMs = obj.getInt("playedDurationMs"),
                        timestamp = obj.getDouble("timestamp"),
                    )
                )
            }
            result
        } catch (_: Exception) {
            emptyList()
        }
    }

    companion object {
        private const val SCROBBLE_FILE_NAME = "aonsoku_scrobble_buffer.json"
    }
}
