package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "playlist")
data class PlaylistEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "name") val name: String,
    @ColumnInfo(name = "comment") val comment: String? = null,
    @ColumnInfo(name = "songCount") val songCount: Int = 0,
    @ColumnInfo(name = "duration") val duration: Int = 0,
    @ColumnInfo(name = "isPublic") val isPublic: Boolean = false,
    @ColumnInfo(name = "owner") val owner: String? = null,
    @ColumnInfo(name = "created") val created: String? = null,
    @ColumnInfo(name = "changed") val changed: String? = null,
    @ColumnInfo(name = "coverArt") val coverArt: String? = null,
    @ColumnInfo(name = "starred") val starred: String? = null,
    @ColumnInfo(name = "starredAt") val starredAt: Long? = null,
)