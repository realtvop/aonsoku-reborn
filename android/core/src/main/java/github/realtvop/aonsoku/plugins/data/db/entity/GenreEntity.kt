package github.realtvop.aonsoku.plugins.data.db.entity
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
@Entity(tableName = "genre")
data class GenreEntity(
    @PrimaryKey val value: String,
    @ColumnInfo(name = "songCount") val songCount: Int? = null,
    @ColumnInfo(name = "albumCount") val albumCount: Int? = null,
)