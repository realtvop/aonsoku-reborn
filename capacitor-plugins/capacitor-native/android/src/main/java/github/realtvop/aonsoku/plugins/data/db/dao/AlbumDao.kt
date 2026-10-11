package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity

@Dao
interface AlbumDao {
    @Query("SELECT * FROM album ORDER BY name ASC LIMIT :limit OFFSET :offset") suspend fun getAll(limit: Int, offset: Int): List<AlbumEntity>
    @Query("SELECT * FROM album WHERE id = :id") suspend fun getById(id: String): AlbumEntity?
    @Query("SELECT * FROM song WHERE albumId = :albumId ORDER BY discNumber ASC, track ASC") suspend fun getSongsByAlbumId(albumId: String): List<SongEntity>
    @Query("SELECT * FROM album WHERE (:search IS NULL OR (name LIKE '%' || :search || '%' OR artist LIKE '%' || :search || '%')) AND (:artistId IS NULL OR artistId = :artistId) AND (:genre IS NULL OR genre = :genre) AND (:fromYear IS NULL OR year >= :fromYear) AND (:toYear IS NULL OR year <= :toYear) AND (:starredOnly = 0 OR starredAt IS NOT NULL) ORDER BY CASE WHEN :sortBy LIKE 'random:%' THEN ((unicode(substr(id, 1, 1)) * 65537 + unicode(substr(id, length(id) / 2, 1)) * 257 + unicode(substr(id, -1, 1))) * (CAST(substr(:sortBy, 8) AS INTEGER) % 99991 + 1)) % 2147483647 END, CASE WHEN :sortBy = 'random' THEN RANDOM() END, CASE WHEN :sortBy = 'artist' THEN artist END COLLATE NOCASE ASC, CASE WHEN :sortBy = 'year' THEN year END DESC, CASE WHEN :sortBy = 'created' THEN created END DESC, CASE WHEN :sortBy = 'starredAt' THEN starredAt END DESC, CASE WHEN :sortBy = 'playCount' THEN playCount END DESC, CASE WHEN :sortBy = 'played' THEN played END DESC, name COLLATE NOCASE ASC, id ASC LIMIT :limit OFFSET :offset")
    suspend fun getFiltered(limit: Int, offset: Int, search: String?, artistId: String?, genre: String?, fromYear: Int?, toYear: Int?, starredOnly: Int, sortBy: String?): List<AlbumEntity>
    @Query("SELECT COUNT(*) FROM album WHERE (:search IS NULL OR (name LIKE '%' || :search || '%' OR artist LIKE '%' || :search || '%')) AND (:artistId IS NULL OR artistId = :artistId) AND (:genre IS NULL OR genre = :genre) AND (:fromYear IS NULL OR year >= :fromYear) AND (:toYear IS NULL OR year <= :toYear) AND (:starredOnly = 0 OR starredAt IS NOT NULL)")
    suspend fun countFiltered(search: String?, artistId: String?, genre: String?, fromYear: Int?, toYear: Int?, starredOnly: Int): Int
    @Query("SELECT COUNT(*) FROM album") suspend fun count(): Int
    @Upsert suspend fun upsert(album: AlbumEntity)
    @Upsert suspend fun bulkUpsert(albums: List<AlbumEntity>)
    @Query("DELETE FROM album") suspend fun deleteAll()
}