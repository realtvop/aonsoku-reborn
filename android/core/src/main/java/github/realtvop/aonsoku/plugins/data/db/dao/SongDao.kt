package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity

@Dao
interface SongDao {
    @Query("SELECT * FROM song ORDER BY title ASC LIMIT :limit OFFSET :offset") suspend fun getAll(limit: Int, offset: Int): List<SongEntity>
    @Query("SELECT * FROM song WHERE id = :id") suspend fun getById(id: String): SongEntity?
    @Query("SELECT * FROM song WHERE id IN (:ids)") suspend fun getByIds(ids: List<String>): List<SongEntity>
    @Query("SELECT * FROM song WHERE albumId = :albumId ORDER BY discNumber ASC, track ASC") suspend fun getByAlbumId(albumId: String): List<SongEntity>
    @Query("SELECT * FROM song WHERE (:search IS NULL OR (title LIKE '%' || :search || '%' OR artist LIKE '%' || :search || '%' OR album LIKE '%' || :search || '%')) AND (:albumId IS NULL OR albumId = :albumId) AND (:artistId IS NULL OR artistId = :artistId) AND (:genre IS NULL OR genre = :genre) AND (:starredOnly = 0 OR starredAt IS NOT NULL) ORDER BY CASE WHEN :sortBy = 'title' THEN title END || CASE WHEN :sortBy = 'artist' THEN artist END || CASE WHEN :sortBy = 'album' THEN album END || CASE WHEN :sortBy = 'starredAt' THEN starredAt END || CASE WHEN :sortBy = 'playCount' THEN playCount END || CASE WHEN :sortBy = 'playedAt' THEN playedAt END || CASE WHEN :sortBy = 'created' THEN created END ASC LIMIT :limit OFFSET :offset")
    suspend fun getFiltered(limit: Int, offset: Int, search: String?, albumId: String?, artistId: String?, genre: String?, starredOnly: Int, sortBy: String?): List<SongEntity>
    @Query("SELECT COUNT(*) FROM song WHERE (:search IS NULL OR (title LIKE '%' || :search || '%' OR artist LIKE '%' || :search || '%' OR album LIKE '%' || :search || '%')) AND (:albumId IS NULL OR albumId = :albumId) AND (:artistId IS NULL OR artistId = :artistId) AND (:genre IS NULL OR genre = :genre) AND (:starredOnly = 0 OR starredAt IS NOT NULL)")
    suspend fun countFiltered(search: String?, albumId: String?, artistId: String?, genre: String?, starredOnly: Int): Int
    @Upsert suspend fun upsert(song: SongEntity)
    @Upsert suspend fun bulkUpsert(songs: List<SongEntity>)
    @Query("DELETE FROM song") suspend fun deleteAll()
    @Query("UPDATE song SET starred = :starred, starredAt = :starredAt WHERE id IN (:ids)") suspend fun updateStarred(ids: List<String>, starred: String?, starredAt: Long?)
    @Query("SELECT id FROM song") suspend fun getAllIds(): List<String>
    @Query("SELECT id FROM song WHERE starredAt IS NOT NULL") suspend fun getStarredSongIds(): List<String>
    @Query("DELETE FROM song WHERE id IN (:ids)") suspend fun deleteByIds(ids: List<String>): Int
    @Query("SELECT COUNT(*) FROM song") suspend fun count(): Int
}