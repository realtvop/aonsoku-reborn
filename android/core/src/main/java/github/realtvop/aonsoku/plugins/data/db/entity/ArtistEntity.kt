package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "artist")
data class ArtistEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "albumCount") val albumCount: Int = 0,
    @ColumnInfo(name = "coverArt") val coverArt: String? = null,
    @ColumnInfo(name = "artistImageUrl") val artistImageUrl: String? = null,
    @ColumnInfo(name = "starred") val starred: String? = null,
    @ColumnInfo(name = "starredAt") val starredAt: Long? = null,
    @ColumnInfo(name = "musicBrainzId") val musicBrainzId: String? = null,
    @ColumnInfo(name = "sortName") val sortName: String? = null,
)