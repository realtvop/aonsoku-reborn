package github.realtvop.aonsoku.data

import android.net.Uri
import github.realtvop.aonsoku.data.api.SubsonicApi
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.Artist
import github.realtvop.aonsoku.data.model.Genre
import github.realtvop.aonsoku.data.model.NamedItem
import github.realtvop.aonsoku.data.model.Playlist
import github.realtvop.aonsoku.data.model.ReplayGain
import github.realtvop.aonsoku.data.model.Song
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.GenreEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistDetailEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import kotlinx.serialization.builtins.ListSerializer

private val json get() = SubsonicApi.json

private val ISO_TIMESTAMP = Regex(
    """^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:?\d{2})?$""",
)

/**
 * Epoch milliseconds of an ISO-8601 server timestamp, or null when it cannot
 * be parsed. Timestamps without an offset are read as UTC. Implemented without
 * `java.time`, which is unavailable below API 26.
 */
fun parseIsoTimestamp(value: String?): Long? {
    val match = ISO_TIMESTAMP.matchEntire(value?.trim().orEmpty()) ?: return null
    val (year, month, day, hour, minute, second, fraction, zone) = match.destructured
    val calendar = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
    calendar.clear()
    calendar.isLenient = false
    return runCatching {
        calendar.set(
            year.toInt(),
            month.toInt() - 1,
            day.toInt(),
            hour.toInt(),
            minute.toInt(),
            second.toInt(),
        )
        val millis = fraction.padEnd(3, '0').take(3).toIntOrNull() ?: 0
        val offsetMinutes = if (zone.isEmpty() || zone == "Z") {
            0
        } else {
            val digits = zone.drop(1).replace(":", "")
            val total = digits.take(2).toInt() * 60 + digits.drop(2).toInt()
            if (zone.startsWith("-")) -total else total
        }
        calendar.timeInMillis + millis - offsetMinutes * 60_000L
    }.getOrNull()
}

fun SongEntity.toModel(): Song = Song(
    id = id,
    parent = parent,
    title = title,
    album = album,
    artist = artist,
    track = track,
    year = year,
    genre = genre,
    coverArt = coverArt,
    size = size,
    contentType = contentType,
    suffix = suffix,
    duration = duration,
    bitRate = bitRate,
    path = path,
    playCount = playCount,
    discNumber = discNumber,
    created = created,
    albumId = albumId,
    artistId = artistId,
    played = played,
    bpm = bpm,
    starred = starred,
    comment = comment,
    sortName = sortName,
    mediaType = mediaType,
    musicBrainzId = musicBrainzId,
    genres = genresJson?.let { raw ->
        runCatching { json.decodeFromString(ListSerializer(NamedItem.serializer()), raw) }
            .getOrNull()
    },
    replayGain = replayGainJson?.let { raw ->
        runCatching { json.decodeFromString(ReplayGain.serializer(), raw) }.getOrNull()
    },
)

fun Song.toEntity(): SongEntity = SongEntity(
    id = id,
    parent = parent,
    title = title,
    album = album,
    artist = artist,
    track = track,
    year = year,
    genre = genre,
    coverArt = coverArt,
    size = size,
    contentType = contentType,
    suffix = suffix,
    duration = duration,
    bitRate = bitRate,
    path = path,
    playCount = playCount,
    discNumber = discNumber,
    created = created,
    albumId = albumId,
    artistId = artistId,
    played = played,
    starred = starred,
    starredAt = parseIsoTimestamp(starred),
    playedAt = parseIsoTimestamp(played),
    bpm = bpm,
    comment = comment,
    sortName = sortName,
    mediaType = mediaType,
    musicBrainzId = musicBrainzId,
    genresJson = genres?.let { json.encodeToString(ListSerializer(NamedItem.serializer()), it) },
    replayGainJson = replayGain?.let { json.encodeToString(ReplayGain.serializer(), it) },
)

fun AlbumEntity.toModel(): Album = Album(
    id = id,
    name = name,
    artist = artist,
    artistId = artistId,
    coverArt = coverArt,
    songCount = songCount,
    duration = duration,
    playCount = playCount,
    created = created,
    starred = starred,
    year = year,
    genre = genre,
    played = played,
)

fun Album.toEntity(): AlbumEntity = AlbumEntity(
    id = id,
    name = name,
    artist = artist.orEmpty(),
    artistId = artistId,
    coverArt = coverArt,
    songCount = songCount,
    duration = duration,
    year = year,
    genre = genre,
    created = created,
    played = played,
    playCount = playCount,
    starred = starred,
    starredAt = parseIsoTimestamp(starred),
)

fun ArtistEntity.toModel(): Artist = Artist(
    id = id,
    name = name,
    coverArt = coverArt,
    albumCount = albumCount,
    starred = starred,
    artistImageUrl = artistImageUrl,
    musicBrainzId = musicBrainzId,
    sortName = sortName,
)

fun PlaylistEntity.toModel(): Playlist = Playlist(
    id = id,
    name = name,
    comment = comment,
    songCount = songCount,
    duration = duration,
    isPublic = isPublic,
    owner = owner,
    created = created,
    changed = changed,
    coverArt = coverArt,
    starred = starred,
)

fun Playlist.toEntity(): PlaylistEntity = PlaylistEntity(
    id = id,
    name = name,
    comment = comment,
    songCount = songCount,
    duration = duration,
    isPublic = isPublic,
    owner = owner,
    created = created,
    changed = changed,
    coverArt = coverArt,
    starred = starred,
    starredAt = parseIsoTimestamp(starred),
)

fun PlaylistDetailEntity.toModel(): Playlist = Playlist(
    id = id,
    name = name,
    comment = comment,
    songCount = songCount,
    duration = duration,
    isPublic = isPublic,
    owner = owner,
    created = created,
    changed = changed,
    coverArt = coverArt,
    starred = starred,
    entry = runCatching { json.decodeFromString(ListSerializer(Song.serializer()), entriesJson) }
        .getOrDefault(emptyList()),
)

fun Playlist.toDetailEntity(): PlaylistDetailEntity = PlaylistDetailEntity(
    id = id,
    name = name,
    comment = comment,
    songCount = songCount,
    duration = duration,
    isPublic = isPublic,
    owner = owner,
    created = created,
    changed = changed,
    coverArt = coverArt,
    starred = starred,
    starredAt = parseIsoTimestamp(starred),
    entriesJson = json.encodeToString(ListSerializer(Song.serializer()), entry.orEmpty()),
)

fun GenreEntity.toModel(): Genre = Genre(value = value, songCount = songCount, albumCount = albumCount)

/** Cover art id for a song, honoring the "always use album covers" preference. */
fun Song.coverArtId(useAlbumCover: Boolean): String? =
    if (useAlbumCover && !albumId.isNullOrEmpty()) albumId else coverArt ?: albumId

/**
 * Converts a song into the queue representation of the native playback
 * service. The stream URL stays symbolic (`aonsoku-media://stream`); the
 * service resolves it against the stored credentials or a cached file.
 */
fun Song.toQueueSong(useAlbumCover: Boolean = false): QueueSong = QueueSong(
    id = id,
    title = title,
    artist = artistLabel,
    artistId = artistId,
    album = album.orEmpty(),
    albumId = albumId,
    duration = duration.toDouble(),
    coverArtId = coverArtId(useAlbumCover),
    streamUrl = Uri.Builder()
        .scheme("aonsoku-media")
        .authority("stream")
        .appendQueryParameter("id", id)
        .build()
        .toString(),
    cachedFileUri = null,
)

/** Minimal song for queue entries whose full metadata is not loaded yet. */
fun QueueSong.toSong(): Song = Song(
    id = id,
    title = title,
    artist = artist,
    artistId = artistId,
    album = album,
    albumId = albumId,
    duration = duration.toInt(),
    coverArt = coverArtId,
)
