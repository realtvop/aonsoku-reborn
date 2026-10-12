package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "song")
data class SongEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "parent") val parent: String? = null,
    @ColumnInfo(name = "title") val title: String,
    @ColumnInfo(name = "album") val album: String? = null,
    @ColumnInfo(name = "artist") val artist: String? = null,
    @ColumnInfo(name = "track") val track: Int? = null,
    @ColumnInfo(name = "year") val year: Int? = null,
    @ColumnInfo(name = "genre") val genre: String? = null,
    @ColumnInfo(name = "coverArt") val coverArt: String? = null,
    @ColumnInfo(name = "size") val size: Long? = null,
    @ColumnInfo(name = "contentType") val contentType: String? = null,
    @ColumnInfo(name = "suffix") val suffix: String? = null,
    @ColumnInfo(name = "duration") val duration: Int = 0,
    @ColumnInfo(name = "bitRate") val bitRate: Int? = null,
    @ColumnInfo(name = "path") val path: String? = null,
    @ColumnInfo(name = "playCount") val playCount: Int? = null,
    @ColumnInfo(name = "discNumber") val discNumber: Int? = null,
    @ColumnInfo(name = "created") val created: String? = null,
    @ColumnInfo(name = "albumId") val albumId: String? = null,
    @ColumnInfo(name = "artistId") val artistId: String? = null,
    @ColumnInfo(name = "played") val played: String? = null,
    @ColumnInfo(name = "starred") val starred: String? = null,
    @ColumnInfo(name = "starredAt") val starredAt: Long? = null,
    @ColumnInfo(name = "playedAt") val playedAt: Long? = null,
    @ColumnInfo(name = "bpm") val bpm: Int? = null,
    @ColumnInfo(name = "comment") val comment: String? = null,
    @ColumnInfo(name = "sortName") val sortName: String? = null,
    @ColumnInfo(name = "mediaType") val mediaType: String? = null,
    @ColumnInfo(name = "musicBrainzId") val musicBrainzId: String? = null,
    @ColumnInfo(name = "genresJson") val genresJson: String? = null,
    @ColumnInfo(name = "replayGainJson") val replayGainJson: String? = null,
)