package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "album")
data class AlbumEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "artist") val artist: String,
    @ColumnInfo(name = "artistId") val artistId: String? = null,
    @ColumnInfo(name = "coverArt") val coverArt: String? = null,
    @ColumnInfo(name = "songCount") val songCount: Int = 0,
    @ColumnInfo(name = "duration") val duration: Int = 0,
    @ColumnInfo(name = "year") val year: Int? = null,
    @ColumnInfo(name = "genre") val genre: String? = null,
    @ColumnInfo(name = "created") val created: String? = null,
    @ColumnInfo(name = "played") val played: String? = null,
    @ColumnInfo(name = "playCount") val playCount: Int? = null,
    @ColumnInfo(name = "starred") val starred: String? = null,
    @ColumnInfo(name = "starredAt") val starredAt: Long? = null,
)