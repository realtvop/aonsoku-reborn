package github.realtvop.aonsoku.plugins.audio

import org.json.JSONObject

data class QueueSong(
    val id: String,
    val title: String,
    val artist: String,
    val artistId: String?,
    val album: String,
    val albumId: String?,
    val duration: Double,
    val coverArtId: String?,
    val streamUrl: String,
    val cachedFileUri: String?
) {
    companion object {
        fun from(dict: JSONObject): QueueSong {
            return QueueSong(
                id = dict.optString("id", ""),
                title = dict.optString("title", ""),
                artist = dict.optString("artist", ""),
                artistId = if (dict.has("artistId") && !dict.isNull("artistId")) dict.getString("artistId") else null,
                album = dict.optString("album", ""),
                albumId = if (dict.has("albumId") && !dict.isNull("albumId")) dict.getString("albumId") else null,
                duration = dict.optDouble("duration", 0.0),
                coverArtId = if (dict.has("coverArtId") && !dict.isNull("coverArtId")) dict.getString("coverArtId") else null,
                streamUrl = dict.optString("streamUrl", ""),
                cachedFileUri = if (dict.has("cachedFileUri") && !dict.isNull("cachedFileUri")) dict.getString("cachedFileUri") else null
            )
        }
    }

    fun toDict(): JSONObject {
        val dict = JSONObject()
        dict.put("id", id)
        dict.put("title", title)
        dict.put("artist", artist)
        dict.put("album", album)
        dict.put("duration", duration)
        dict.put("streamUrl", streamUrl)
        artistId?.let { dict.put("artistId", it) }
        albumId?.let { dict.put("albumId", it) }
        coverArtId?.let { dict.put("coverArtId", it) }
        cachedFileUri?.let { dict.put("cachedFileUri", it) }
        return dict
    }
}

data class QueueSourceId(
    val type: String,
    val id: String
) {
    companion object {
        fun from(dict: JSONObject?): QueueSourceId? {
            if (dict == null) return null
            val type = if (dict.has("type") && !dict.isNull("type")) dict.getString("type") else return null
            val id = if (dict.has("id") && !dict.isNull("id")) dict.getString("id") else return null
            return QueueSourceId(type, id)
        }
    }

    fun toDict(): JSONObject {
        val dict = JSONObject()
        dict.put("type", type)
        dict.put("id", id)
        return dict
    }
}

enum class LoopState(val value: String) {
    OFF("off"),
    ONE("one"),
    ALL("all");

    companion object {
        fun fromValue(value: String): LoopState {
            return entries.firstOrNull { it.value == value } ?: OFF
        }
    }
}

enum class QueueAdvanceReason(val value: String) {
    NEXT("next"),
    PREVIOUS("previous"),
    ENDED("ended"),
    SKIP("skip")
}
