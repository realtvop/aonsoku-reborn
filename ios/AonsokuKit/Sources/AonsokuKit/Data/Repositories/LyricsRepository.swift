import Foundation
import GRDB

struct LyricsRepository {
    let db: DatabasePool

    func getBySongId(_ songId: String) throws -> LyricsRecord? {
        try db.read { db in
            try LyricsRecord.fetchOne(db, key: songId)
        }
    }

    func upsert(_ record: LyricsRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func updateAccessTime(songId: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE lyrics SET lastAccessedAt = ? WHERE songId = ?",
                arguments: [Int(Date().timeIntervalSince1970 * 1000), songId]
            )
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try LyricsRecord.deleteAll(db)
        }
    }
}
