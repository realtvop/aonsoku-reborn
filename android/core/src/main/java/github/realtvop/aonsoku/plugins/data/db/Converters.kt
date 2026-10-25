package github.realtvop.aonsoku.plugins.data.db
import androidx.room.TypeConverter
class Converters {
    @TypeConverter fun fromTimestamp(value: Long?): Long? = value
    @TypeConverter fun toTimestamp(value: Long?): Long? = value
}