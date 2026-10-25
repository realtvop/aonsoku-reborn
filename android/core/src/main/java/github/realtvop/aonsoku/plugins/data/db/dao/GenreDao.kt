package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.GenreEntity

@Dao
interface GenreDao {
    @Query("SELECT * FROM genre ORDER BY value ASC") suspend fun getAll(): List<GenreEntity>
    @Upsert suspend fun bulkUpsert(genres: List<GenreEntity>)
    @Query("DELETE FROM genre") suspend fun deleteAll()
    @Query("INSERT INTO genre (value, songCount, albumCount) VALUES (:value, :songCount, :albumCount)") suspend fun insert(value: String, songCount: Int?, albumCount: Int?)
}