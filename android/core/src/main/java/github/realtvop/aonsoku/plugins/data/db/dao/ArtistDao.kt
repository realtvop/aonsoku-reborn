package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity

@Dao
interface ArtistDao {
    @Query("SELECT * FROM artist ORDER BY name ASC LIMIT :limit OFFSET :offset")
    suspend fun getAll(limit: Int, offset: Int): List<ArtistEntity>
    @Query("SELECT * FROM artist WHERE id = :id")
    suspend fun getById(id: String): ArtistEntity?
    @Query("SELECT * FROM artist WHERE (:search IS NULL OR name LIKE '%' || :search || '%') AND (:starredOnly = 0 OR starredAt IS NOT NULL) ORDER BY CASE WHEN :sortBy = 'starredAt' THEN starredAt END DESC, CASE WHEN :sortBy != 'starredAt' OR :sortBy IS NULL THEN name END ASC LIMIT :limit OFFSET :offset")
    suspend fun getFiltered(limit: Int, offset: Int, search: String?, starredOnly: Int, sortBy: String?): List<ArtistEntity>
    @Query("SELECT COUNT(*) FROM artist WHERE (:search IS NULL OR name LIKE '%' || :search || '%') AND (:starredOnly = 0 OR starredAt IS NOT NULL)")
    suspend fun countFiltered(search: String?, starredOnly: Int): Int
    @Upsert suspend fun upsert(artist: ArtistEntity)
    @Upsert suspend fun bulkUpsert(artists: List<ArtistEntity>)
    @Query("DELETE FROM artist") suspend fun deleteAll()
    @Query("SELECT COUNT(*) FROM artist") suspend fun count(): Int
}