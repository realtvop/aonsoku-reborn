package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity

@Dao
interface CacheMetaDao {
    @Query("SELECT * FROM cacheMeta WHERE key = :key") suspend fun getByKey(key: String): CacheMetaEntity?
    @Query("SELECT COUNT(*) FROM cacheMeta") suspend fun totalItems(): Int
    @Query("SELECT COALESCE(SUM(sizeBytes), 0) FROM cacheMeta") suspend fun totalSizeBytes(): Long
    @Query("SELECT COUNT(*) FROM cacheMeta WHERE type = 'audio'") suspend fun audioCount(): Int
    @Query("SELECT COUNT(*) FROM cacheMeta WHERE type = 'cover'") suspend fun coverCount(): Int
    @Upsert suspend fun upsert(meta: CacheMetaEntity)
    @Upsert suspend fun bulkUpsert(metas: List<CacheMetaEntity>)
    @Query("DELETE FROM cacheMeta WHERE key = :key") suspend fun delete(key: String)
    @Query("DELETE FROM cacheMeta WHERE type = :type") suspend fun deleteByType(type: String): Int
    @Query("DELETE FROM cacheMeta") suspend fun deleteAll()
}