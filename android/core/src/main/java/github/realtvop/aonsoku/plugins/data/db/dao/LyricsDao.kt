package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.LyricsEntity

@Dao
interface LyricsDao {
    @Query("SELECT * FROM lyrics WHERE songId = :songId") suspend fun getBySongId(songId: String): LyricsEntity?
    @Upsert suspend fun upsert(lyrics: LyricsEntity)
    @Query("UPDATE lyrics SET lastAccessedAt = :now WHERE songId = :songId") suspend fun updateAccessTime(songId: String, now: Long)
    @Query("DELETE FROM lyrics") suspend fun deleteAll()
}