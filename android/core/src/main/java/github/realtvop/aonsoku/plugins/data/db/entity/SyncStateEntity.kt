package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "syncState")
data class SyncStateEntity(
    @PrimaryKey val key: String,
    @ColumnInfo(name = "lastSyncedAt") val lastSyncedAt: Long? = null,
    @ColumnInfo(name = "phase") val phase: String? = null,
    @ColumnInfo(name = "checkpointJson") val checkpointJson: String? = null,
)