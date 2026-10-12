package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistDetailEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistEntity

@Dao
interface PlaylistDao {
    @Query("SELECT * FROM playlist ORDER BY name ASC LIMIT :limit OFFSET :offset") suspend fun getAll(limit: Int, offset: Int): List<PlaylistEntity>
    @Query("SELECT * FROM playlist WHERE id = :id") suspend fun getById(id: String): PlaylistEntity?
    @Query("SELECT * FROM playlistDetail WHERE id = :id") suspend fun getDetailById(id: String): PlaylistDetailEntity?
    @Upsert suspend fun upsert(playlist: PlaylistEntity)
    @Upsert suspend fun bulkUpsert(playlists: List<PlaylistEntity>)
    @Upsert suspend fun upsertDetail(detail: PlaylistDetailEntity)
    @Upsert suspend fun bulkUpsertDetails(details: List<PlaylistDetailEntity>)
    @Query("SELECT id FROM playlistDetail") suspend fun getAllDetailIds(): List<String>
    @Query("DELETE FROM playlistDetail WHERE id IN (:ids)") suspend fun deleteDetails(ids: List<String>)
    @Query("DELETE FROM playlist") suspend fun deleteAll()
    @Query("DELETE FROM playlistDetail") suspend fun deleteAllDetails()
    @Query("SELECT COUNT(*) FROM playlist") suspend fun count(): Int
}