import Foundation
import GRDB

struct CacheMetaRepository {
    let db: DatabasePool

    func getByKey(_ key: String) throws -> CacheMetaRecord? {
        try db.read { db in
            try CacheMetaRecord.fetchOne(db, key: key)
        }
    }

    func getStats() throws -> (totalItems: Int, totalSizeBytes: Int, audioCount: Int, coverCount: Int) {
        try db.read { db in
            let totalItems = try CacheMetaRecord.fetchCount(db)
            let totalSize = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM cacheMeta") ?? 0
            let audioCount = try CacheMetaRecord.filter(Column("type") == "audio").fetchCount(db)
            let coverCount = try CacheMetaRecord.filter(Column("type") == "cover").fetchCount(db)
            return (totalItems, totalSize, audioCount, coverCount)
        }
    }

    func upsert(_ record: CacheMetaRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func bulkUpsert(_ records: [CacheMetaRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func delete(key: String) throws {
        try db.write { db in
            _ = try CacheMetaRecord.deleteOne(db, key: key)
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try CacheMetaRecord.deleteAll(db)
        }
    }
}
