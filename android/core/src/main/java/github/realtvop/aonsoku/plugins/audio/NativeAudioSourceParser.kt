package github.realtvop.aonsoku.plugins.audio

import org.json.JSONObject

data class ParsedMetadata(
    val title: String?,
    val artist: String?,
    val album: String?,
    val duration: Double?,
    val artworkUrl: String?
)

data class ParsedSource(
    val url: String?,
    val uri: String?,
    val songId: String?,
    val radioId: String?,
    val kind: String
)

object NativeAudioSourceParser {
    fun parseSource(sourceJson: JSONObject?): ParsedSource? {
        if (sourceJson == null) return null
        val kind = sourceJson.optString("kind", "")
        val url = if (sourceJson.has("url") && !sourceJson.isNull("url")) sourceJson.getString("url") else null
        val uri = if (sourceJson.has("uri") && !sourceJson.isNull("uri")) sourceJson.getString("uri") else null
        val songId = if (sourceJson.has("songId") && !sourceJson.isNull("songId")) sourceJson.getString("songId") else null
        val radioId = if (sourceJson.has("radioId") && !sourceJson.isNull("radioId")) sourceJson.getString("radioId") else null

        return ParsedSource(
            url = url,
            uri = uri,
            songId = songId,
            radioId = radioId,
            kind = kind
        )
    }

    fun parseMetadata(metadataJson: JSONObject?): ParsedMetadata? {
        if (metadataJson == null) return null
        val title = if (metadataJson.has("title") && !metadataJson.isNull("title")) metadataJson.getString("title") else null
        val artist = if (metadataJson.has("artist") && !metadataJson.isNull("artist")) metadataJson.getString("artist") else null
        val album = if (metadataJson.has("album") && !metadataJson.isNull("album")) metadataJson.getString("album") else null
        val duration = if (metadataJson.has("duration") && !metadataJson.isNull("duration")) metadataJson.optDouble("duration") else null
        val artworkUrl = if (metadataJson.has("artworkUrl") && !metadataJson.isNull("artworkUrl")) metadataJson.getString("artworkUrl") else null

        return ParsedMetadata(
            title = title,
            artist = artist,
            album = album,
            duration = duration,
            artworkUrl = artworkUrl
        )
    }
}
