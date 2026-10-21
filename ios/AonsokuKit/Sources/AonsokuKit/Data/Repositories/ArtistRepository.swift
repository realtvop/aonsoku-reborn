import Foundation
import GRDB

struct ArtistRepository {
    let db: DatabasePool

    func getAll(limit: Int, offset: Int, filter: ArtistQueryFilter) throws -> (items: [ArtistRecord], total: Int) {
        try db.read { db in
            var query = ArtistRecord.all()

            if let search = filter.search, !search.isEmpty,
               let condition = SearchHelper.buildCondition(query: search, columns: ["name"]) {
                query = query.filter(condition)
            }
            if filter.starredOnly == true {
                query = query.filter(Column("starredAt") != nil)
            }

            let total = try query.fetchCount(db)

            switch filter.sortBy {
            case "starredAt":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("starredAt").desc)
                    : query.order(Column("starredAt").asc)
            default:
                query = filter.sortOrder == "desc"
                    ? query.order(Column("name").desc)
                    : query.order(Column("name").asc)
            }

            let items = try query.limit(limit, offset: offset).fetchAll(db)
            return (items, total)
        }
    }

    func getById(_ id: String) throws -> ArtistRecord? {
        try db.read { db in
            try ArtistRecord.fetchOne(db, key: id)
        }
    }

    func upsert(_ record: ArtistRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func bulkUpsert(_ records: [ArtistRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try ArtistRecord.deleteAll(db)
        }
    }

    func starredIds() throws -> Set<String> {
        try db.read { db in
            Set(try String.fetchAll(
                db,
                ArtistRecord
                    .filter(Column("starred") != nil)
                    .select(Column("id"))
            ))
        }
    }

    func updateStarred(ids: [String], starred: String?, starredAt: Int?) throws {
        guard !ids.isEmpty else { return }
        _ = try db.write { db in
            try ArtistRecord
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("starred").set(to: starred),
                    Column("starredAt").set(to: starredAt)
                )
        }
    }

    func count() throws -> Int {
        try db.read { db in
            try ArtistRecord.fetchCount(db)
        }
    }
}

struct ArtistQueryFilter {
    var search: String?
    var starredOnly: Bool?
    var sortBy: String?
    var sortOrder: String?
}
