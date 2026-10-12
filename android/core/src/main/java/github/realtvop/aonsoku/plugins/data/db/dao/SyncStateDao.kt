package github.realtvop.aonsoku.plugins.data.db.dao

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Upsert
import github.realtvop.aonsoku.plugins.data.db.entity.SyncStateEntity

@Dao
interface SyncStateDao {
    @Query("SELECT * FROM syncState WHERE key = :key") suspend fun get(key: String): SyncStateEntity?
    @Query("SELECT lastSyncedAt FROM syncState WHERE key = :key") suspend fun getLastSyncedAt(key: String): Long?
    @Upsert suspend fun upsert(state: SyncStateEntity)
    @Query("DELETE FROM syncState") suspend fun deleteAll()
}