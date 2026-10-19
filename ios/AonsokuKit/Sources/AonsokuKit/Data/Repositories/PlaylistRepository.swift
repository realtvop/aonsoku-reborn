import Foundation
import GRDB

struct PlaylistRepository {
    let db: DatabasePool

    func getAll(limit: Int, offset: Int) throws -> (items: [PlaylistRecord], total: Int) {
        try db.read { db in
            let total = try PlaylistRecord.fetchCount(db)
            let items = try PlaylistRecord
                .order(Column("name").asc)
                .limit(limit, offset: offset)
                .fetchAll(db)
            return (items, total)
        }
    }

    func getById(_ id: String) throws -> PlaylistRecord? {
        try db.read { db in
            try PlaylistRecord.fetchOne(db, key: id)
        }
    }

    func getDetailById(_ id: String) throws -> PlaylistDetailRecord? {
        try db.read { db in
            try PlaylistDetailRecord.fetchOne(db, key: id)
        }
    }

    func upsert(_ record: PlaylistRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func bulkUpsert(_ records: [PlaylistRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func upsertDetail(_ record: PlaylistDetailRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func bulkUpsertDetails(_ records: [PlaylistDetailRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func deleteDetails(ids: [String]) throws {
        try db.write { db in
            _ = try PlaylistDetailRecord
                .filter(ids.contains(Column("id")))
                .deleteAll(db)
        }
    }

    func getAllDetailIds() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM playlistDetail")
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try PlaylistRecord.deleteAll(db)
            _ = try PlaylistDetailRecord.deleteAll(db)
        }
    }

    func count() throws -> Int {
        try db.read { db in
            try PlaylistRecord.fetchCount(db)
        }
    }
}
