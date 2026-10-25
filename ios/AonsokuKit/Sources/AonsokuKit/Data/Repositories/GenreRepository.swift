import Foundation
import GRDB

struct GenreRepository {
    let db: DatabasePool

    func getAll() throws -> [GenreRecord] {
        try db.read { db in
            try GenreRecord.order(Column("value").asc).fetchAll(db)
        }
    }

    func bulkUpsert(_ records: [GenreRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func replaceAll(_ records: [GenreRecord]) throws {
        try db.write { db in
            _ = try GenreRecord.deleteAll(db)
            for record in records {
                try record.insert(db)
            }
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try GenreRecord.deleteAll(db)
        }
    }
}
