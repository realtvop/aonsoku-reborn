package github.realtvop.aonsoku.plugins.lyrics

import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder

/** Native lyric fetching/cache/selection. No Activity, JS, or WebView dependency. */
data class LyricLine(val seconds: Double?, val text: String)
data class LyricsTrack(val body: String = "", val source: String = "", val romaji: String? = null) {
    val lines: List<LyricLine> get() = LyricsParser.parse(body)
    val synced: Boolean get() = lines.any { it.seconds != null }
}
data class LyricsCandidate(val title: String, val artist: String, val body: String, val romaji: String? = null)

object LyricsParser {
    private val stamp = Regex("\\[(\\d+):(\\d{2})(?:[.:](\\d{1,3}))?]")
    fun parse(body: String): List<LyricLine> {
        val offset = Regex("\\[offset:([+-]?\\d+)]", RegexOption.IGNORE_CASE).find(body)?.groupValues?.get(1)?.toDoubleOrNull()?.div(1000) ?: 0.0
        val result = body.lineSequence().flatMap { line ->
            val times = stamp.findAll(line).toList()
            if (times.isEmpty()) {
                if (line.isBlank() || Regex("^\\[[a-zA-Z]+:.*]$").matches(line.trim())) emptyList()
                else listOf(LyricLine(null, line.trim()))
            } else {
                val text = stamp.replace(line, "").trim()
                times.map { m ->
                    val fraction = m.groupValues[3].let { if (it.isEmpty()) 0.0 else it.toDouble() / Math.pow(10.0, it.length.toDouble()) }
                    LyricLine(m.groupValues[1].toInt() * 60 + m.groupValues[2].toInt() + fraction + offset, text)
                }
            }.asSequence()
        }.toList()
        return if (result.any { it.seconds != null }) result.filter { it.seconds != null }.sortedBy { it.seconds } else result
    }
}

class LyricsService(private val library: LibraryService, private val preferences: PreferencesService) {
    suspend fun load(song: SongEntity, force: Boolean = false): LyricsTrack {
        val prefs = preferences.getAllPreferences()
        if (prefs["native.lyrics.disabled.${song.id}"] == "true") return LyricsTrack(source = "Disabled")
        val selected = prefs["native.lyrics.selected.${song.id}"] == "true"
        if (!force || selected) library.getLyrics(song.id)?.let { return LyricsTrack(it.content, if (selected) "Selected lyrics" else "Offline cache", prefs["native.lyrics.romaji.${song.id}"]) }
        val state = runCatching { JSONObject(prefs["player_store"] ?: "{}").getJSONObject("state").getJSONObject("settings") }.getOrDefault(JSONObject())
        val settings = state.optJSONObject("lyrics") ?: JSONObject()
        val order = settings.optJSONArray("sourcePriority") ?: JSONArray(listOf("navidrome", "lrclib", "custom"))
        var fallback: LyricsTrack? = null
        for (i in 0 until order.length()) {
            val source = order.optString(i)
            val track = try {
                when (source) {
                    "navidrome" -> server(song)
                    "lrclib" -> if (state.optJSONObject("privacy")?.optBoolean("lrcLibEnabled", true) != false) lrclib(song) else null
                    "custom" -> if (settings.optBoolean("customServerEnabled")) customCandidates(song.title, song.artist.orEmpty(), settings).firstOrNull()?.let { LyricsTrack(it.body, "Custom server", it.romaji) } else null
                    else -> null
                }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            if (track?.body.isNullOrBlank()) continue
            if (fallback == null) fallback = track
            if (!settings.optBoolean("preferSyncedLyrics") || track!!.synced) { fallback = track; break }
        }
        val result = fallback ?: LyricsTrack(source = "No lyrics found")
        if (result.body.isNotBlank()) library.storeLyrics(song.id, result.body, result.synced)
        return result
    }
    private suspend fun server(song: SongEntity): LyricsTrack? {
        try {
            val response = library.serverRequest("getLyricsBySongId", listOf("id" to song.id))
            val tracks = response.optJSONObject("lyricsList")?.optJSONArray("structuredLyrics")
            val track = tracks?.optJSONObject(0)
            val lines = track?.optJSONArray("line")
            if (lines != null && lines.length() > 0) {
                val timed = track.optBoolean("synced")
                val body = (0 until lines.length()).joinToString("\n") { i ->
                    val line = lines.getJSONObject(i)
                    if (timed) "[${line.optLong("start") / 60000}:${"%02d".format(line.optLong("start") / 1000 % 60)}.${"%03d".format(line.optLong("start") % 1000)}]${line.optString("value")}" else line.optString("value")
                }
                return LyricsTrack(body, "Server")
            }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { }
        val response = library.serverRequest("getLyrics", listOf("artist" to song.artist.orEmpty(), "title" to song.title))
        return response.optJSONObject("lyrics")?.optString("value")?.takeIf(String::isNotBlank)?.let { LyricsTrack(it, "Server") }
    }
    private suspend fun lrclib(song: SongEntity): LyricsTrack? {
        val response = JSONObject(getText("https://lrclib.net/api/get", listOf("artist_name" to song.artist.orEmpty(), "track_name" to song.title, "album_name" to song.album.orEmpty(), "duration" to song.duration.toString())))
        return response.optString("syncedLyrics").takeIf { it.isNotBlank() && it != "null" }?.let { LyricsTrack(it, "LRCLIB") }
            ?: response.optString("plainLyrics").takeIf { it.isNotBlank() && it != "null" }?.let { LyricsTrack(it, "LRCLIB") }
    }
    suspend fun search(title: String, artist: String): List<LyricsCandidate> {
        val state = runCatching { JSONObject(preferences.getAllPreferences()["player_store"] ?: "{}").getJSONObject("state").getJSONObject("settings") }.getOrDefault(JSONObject())
        val settings = state.optJSONObject("lyrics") ?: JSONObject()
        val candidates = mutableListOf<LyricsCandidate>()
        if (settings.optBoolean("customServerEnabled")) candidates += customCandidates(title, artist, settings)
        if (state.optJSONObject("privacy")?.optBoolean("lrcLibEnabled", true) != false) {
            val rows = JSONArray(getText("https://lrclib.net/api/search", listOf("track_name" to title, "artist_name" to artist)))
            for (i in 0 until rows.length()) { val r = rows.getJSONObject(i); val body = r.optString("syncedLyrics").takeIf { it.isNotBlank() && it != "null" } ?: r.optString("plainLyrics"); if (body.isNotBlank() && body != "null") candidates += LyricsCandidate(r.optString("trackName"), r.optString("artistName"), body) }
        }
        return candidates
    }
    private suspend fun customCandidates(title: String, artist: String, settings: JSONObject): List<LyricsCandidate> {
        val url = settings.optString("customServerUrl")
        if (url.isBlank()) return emptyList()
        val raw = getText(url, listOf("title" to title, "artist" to artist, "offset" to "0", "limit" to "30"), settings.optString("customServerPassword"))
        if (!raw.trimStart().startsWith("[")) return listOf(LyricsCandidate(title, artist, raw))
        val rows = JSONArray(raw)
        return (0 until rows.length()).mapNotNull { i -> val r = rows.optJSONObject(i) ?: return@mapNotNull null; r.optString("lyrics").takeIf(String::isNotBlank)?.let { LyricsCandidate(r.optString("title", title), r.optString("artist", artist), it, r.optString("romaji", null)) } }
    }
    suspend fun select(songId: String, body: String, romaji: String? = null) {
        library.storeLyrics(songId, body, LyricsParser.parse(body).any { it.seconds != null })
        preferences.setPreference("native.lyrics.selected.$songId", "true")
        preferences.setPreference("native.lyrics.disabled.$songId", "false")
        romaji?.let { preferences.setPreference("native.lyrics.romaji.$songId", it) }
    }
    private suspend fun getText(base: String, params: List<Pair<String, String>>, password: String? = null): String = withContext(Dispatchers.IO) {
        val uri = URI(base.trim())
        require(uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank()) { "Invalid lyrics server URL" }
        val query = params.joinToString("&") { (k, v) -> "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}" }
        val connection = java.net.URL("${base.trim()}${if (uri.rawQuery == null) "?" else "&"}$query").openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15000; connection.readTimeout = 15000
            connection.setRequestProperty("Lrclib-Client", "Aonsoku Android")
            if (!password.isNullOrBlank()) connection.setRequestProperty("Authorization", password)
            check(connection.responseCode in 200..299) { "Lyrics server returned HTTP ${connection.responseCode}" }
            connection.inputStream.bufferedReader().use { it.readText() }
        } finally { connection.disconnect() }
    }
}
