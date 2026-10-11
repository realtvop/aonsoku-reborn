package github.realtvop.aonsoku.plugins.data

import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import org.json.JSONObject
import java.time.Instant

/** Shared server-to-Room decoding used by sync and native library mutations. */
object NativeLibraryCodec {
    fun requestPath(endpoint: String, params: List<Pair<String, String>>): String {
        val query = params.joinToString("&") { (key, value) ->
            "${java.net.URLEncoder.encode(key, "UTF-8")}=${java.net.URLEncoder.encode(value, "UTF-8")}"
        }
        return "$endpoint.view${if (query.isEmpty()) "" else "?$query"}"
    }

    fun parseSong(item: JSONObject?): SongEntity? {
        if (item == null) return null; val id = item.optString("id", null) ?: return null; val t = item.optString("title", null) ?: return null
        return SongEntity(
            id = id,
            parent = item.optString("parent", null),
            title = t,
            album = item.optString("album", null),
            artist = item.optString("artist", null),
            track = if (item.has("track")) item.optInt("track") else null,
            year = if (item.has("year")) item.optInt("year") else null,
            genre = item.optString("genre", null),
            coverArt = item.optString("coverArt", null),
            size = if (item.has("size")) item.optLong("size") else null,
            contentType = item.optString("contentType", null),
            suffix = item.optString("suffix", null),
            duration = item.optInt("duration", 0),
            bitRate = if (item.has("bitRate")) item.optInt("bitRate") else null,
            path = item.optString("path", null),
            playCount = if (item.has("playCount")) item.optInt("playCount") else null,
            discNumber = if (item.has("discNumber")) item.optInt("discNumber") else null,
            created = item.optString("created", null),
            albumId = item.optString("albumId", null),
            artistId = item.optString("artistId", null),
            played = item.optString("played", null),
            starred = item.optString("starred", null),
            starredAt = toEpoch(item.optString("starred", null)),
            playedAt = toEpoch(item.optString("playedAt", null)),
            bpm = if (item.has("bpm")) item.optInt("bpm") else null,
            comment = item.optString("comment", null),
            sortName = item.optString("sortName", null),
            mediaType = item.optString("mediaType", null),
            musicBrainzId = item.optString("musicBrainzId", null),
            genresJson = item.optJSONArray("genres")?.toString(),
            replayGainJson = item.optJSONObject("replayGain")?.toString()
        )
    }

    private fun toEpoch(raw: String?): Long? = raw?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
}
