package github.realtvop.aonsoku.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class NamedItem(val name: String = "")

@Serializable
data class FeaturedArtist(val id: String = "", val name: String = "")

@Serializable
data class Contributor(val role: String = "", val artist: FeaturedArtist = FeaturedArtist())

@Serializable
data class ReplayGain(
    val trackGain: Double? = null,
    val trackPeak: Double? = null,
    val albumGain: Double? = null,
    val albumPeak: Double? = null,
)

@Serializable
data class Song(
    val id: String,
    val parent: String? = null,
    val title: String = "",
    val album: String? = null,
    val artist: String? = null,
    val track: Int? = null,
    val year: Int? = null,
    val genre: String? = null,
    val coverArt: String? = null,
    val size: Long? = null,
    val contentType: String? = null,
    val suffix: String? = null,
    val duration: Int = 0,
    val bitRate: Int? = null,
    val path: String? = null,
    val playCount: Int? = null,
    val discNumber: Int? = null,
    val created: String? = null,
    val albumId: String? = null,
    val artistId: String? = null,
    val played: String? = null,
    val bpm: Int? = null,
    val starred: String? = null,
    val comment: String? = null,
    val sortName: String? = null,
    val mediaType: String? = null,
    val musicBrainzId: String? = null,
    val genres: List<NamedItem>? = null,
    val replayGain: ReplayGain? = null,
    val channelCount: Int? = null,
    val samplingRate: Int? = null,
    val bitDepth: Int? = null,
    val artists: List<FeaturedArtist>? = null,
    val displayArtist: String? = null,
    val albumArtists: List<FeaturedArtist>? = null,
    val displayAlbumArtist: String? = null,
    val contributors: List<Contributor>? = null,
    val displayComposer: String? = null,
) {
    val isStarred: Boolean get() = !starred.isNullOrEmpty()

    val artistLabel: String get() = displayArtist?.takeIf { it.isNotBlank() } ?: artist.orEmpty()
}

@Serializable
data class Album(
    val id: String,
    val name: String = "",
    val artist: String? = null,
    val artistId: String? = null,
    val coverArt: String? = null,
    val songCount: Int = 0,
    val duration: Int = 0,
    val playCount: Int? = null,
    val created: String? = null,
    val starred: String? = null,
    val year: Int? = null,
    val genre: String? = null,
    val played: String? = null,
    val genres: List<NamedItem>? = null,
    val musicBrainzId: String? = null,
    val isCompilation: Boolean? = null,
    val recordLabels: List<NamedItem>? = null,
    val artists: List<FeaturedArtist>? = null,
    val displayArtist: String? = null,
    val version: String? = null,
    val song: List<Song>? = null,
) {
    val isStarred: Boolean get() = !starred.isNullOrEmpty()

    val artistLabel: String get() = displayArtist?.takeIf { it.isNotBlank() } ?: artist.orEmpty()
}

@Serializable
data class Artist(
    val id: String,
    val name: String = "",
    val coverArt: String? = null,
    val albumCount: Int = 0,
    val starred: String? = null,
    val artistImageUrl: String? = null,
    val musicBrainzId: String? = null,
    val sortName: String? = null,
    val album: List<Album>? = null,
) {
    val isStarred: Boolean get() = !starred.isNullOrEmpty()
}

@Serializable
data class ArtistInfo(
    val biography: String? = null,
    val musicBrainzId: String? = null,
    val lastFmUrl: String? = null,
    val smallImageUrl: String? = null,
    val mediumImageUrl: String? = null,
    val largeImageUrl: String? = null,
    val similarArtist: List<Artist>? = null,
)

@Serializable
data class AlbumInfo(
    val notes: String? = null,
    val musicBrainzId: String? = null,
    val lastFmUrl: String? = null,
)

@Serializable
data class Playlist(
    val id: String,
    val name: String = "",
    val comment: String? = null,
    val songCount: Int = 0,
    val duration: Int = 0,
    @SerialName("public") val isPublic: Boolean = false,
    val owner: String? = null,
    val created: String? = null,
    val changed: String? = null,
    val coverArt: String? = null,
    val starred: String? = null,
    val entry: List<Song>? = null,
)

@Serializable
data class Radio(
    val id: String,
    val name: String = "",
    val streamUrl: String = "",
    val homePageUrl: String? = null,
)

@Serializable
data class Genre(
    val value: String = "",
    val songCount: Int? = null,
    val albumCount: Int? = null,
)

@Serializable
data class SearchResult(
    val artist: List<Artist> = emptyList(),
    val album: List<Album> = emptyList(),
    val song: List<Song> = emptyList(),
) {
    val isEmpty: Boolean get() = artist.isEmpty() && album.isEmpty() && song.isEmpty()
}

/** `subsonic-response` envelope fields returned by every endpoint. */
@Serializable
data class ServerInfo(
    val status: String = "",
    val version: String = "",
    val type: String = "",
    val serverVersion: String = "",
    val openSubsonic: Boolean = false,
)

@Serializable
data class ScanStatus(
    val scanning: Boolean = false,
    val count: Long = 0,
    val folderCount: Long? = null,
    val lastScan: String? = null,
)

/** A page of albums plus the server-reported total (`x-total-count`, 0 if absent). */
data class AlbumPage(val albums: List<Album>, val total: Int)
