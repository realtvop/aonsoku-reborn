package github.realtvop.aonsoku.plugins.audio

import github.realtvop.aonsoku.plugins.data.db.dao.CacheMetaDao
import github.realtvop.aonsoku.plugins.data.db.entity.CacheMetaEntity

/** The cache index in memory, behaving like the Room table. */
class FakeCacheMetaDao : CacheMetaDao {
    val rows = LinkedHashMap<String, CacheMetaEntity>()

    override suspend fun getByKey(key: String): CacheMetaEntity? = rows[key]

    override suspend fun totalItems(): Int = rows.size

    override suspend fun totalSizeBytes(): Long = rows.values.sumOf { it.sizeBytes }

    override suspend fun audioCount(): Int = rows.values.count { it.type == "audio" }

    override suspend fun coverCount(): Int = rows.values.count { it.type == "cover" }

    override suspend fun upsert(meta: CacheMetaEntity) {
        rows[meta.key] = meta
    }

    override suspend fun bulkUpsert(metas: List<CacheMetaEntity>) {
        metas.forEach { rows[it.key] = it }
    }

    override suspend fun delete(key: String) {
        rows.remove(key)
    }

    override suspend fun deleteByType(type: String): Int {
        val keys = rows.values.filter { it.type == type }.map { it.key }
        keys.forEach(rows::remove)
        return keys.size
    }

    override suspend fun deleteAll() = rows.clear()

    override suspend fun getAll(): List<CacheMetaEntity> = rows.values.sortedByDescending { it.cachedAt }

    override suspend fun getByTypeOldestFirst(type: String): List<CacheMetaEntity> =
        rows.values.filter { it.type == type }.sortedBy { it.lastAccessedAt }

    override suspend fun getByTypeAndSource(type: String, source: String): List<CacheMetaEntity> =
        rows.values.filter { it.type == type && it.source == source }.sortedBy { it.lastAccessedAt }

    override suspend fun sizeByType(type: String): Long =
        rows.values.filter { it.type == type }.sumOf { it.sizeBytes }

    override suspend fun touch(key: String, now: Long) {
        rows[key]?.let { rows[key] = it.copy(lastAccessedAt = now) }
    }

    override suspend fun deleteKeys(keys: List<String>) {
        keys.forEach(rows::remove)
    }
}
