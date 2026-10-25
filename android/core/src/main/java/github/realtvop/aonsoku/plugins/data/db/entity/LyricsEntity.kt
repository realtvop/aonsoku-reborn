package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "lyrics")
data class LyricsEntity(
    @PrimaryKey @ColumnInfo(name = "songId") val songId: String,
    @ColumnInfo(name = "content") val content: String,
    @ColumnInfo(name = "synced") val synced: Boolean? = null,
    @ColumnInfo(name = "cachedAt") val cachedAt: Long,
    @ColumnInfo(name = "lastAccessedAt") val lastAccessedAt: Long,
)