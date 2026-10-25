package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
@Entity(tableName = "cacheMeta", indices = [Index("id"), Index("type"), Index("source"), Index("lastAccessedAt"), Index("cachedAt")])
data class CacheMetaEntity(
    @PrimaryKey val key: String,
    @ColumnInfo(name = "id") val id: String,
    @ColumnInfo(name = "type") val type: String,
    @ColumnInfo(name = "source") val source: String,
    @ColumnInfo(name = "triggersJson") val triggersJson: String? = null,
    @ColumnInfo(name = "coverSize") val coverSize: String? = null,
    @ColumnInfo(name = "sizeBytes") val sizeBytes: Long,
    @ColumnInfo(name = "cachedAt") val cachedAt: Long,
    @ColumnInfo(name = "lastAccessedAt") val lastAccessedAt: Long,
    @ColumnInfo(name = "removedFromServer") val removedFromServer: Boolean? = null,
)