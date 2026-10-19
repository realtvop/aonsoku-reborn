import Foundation
import GRDB

struct SongRepository {
    let db: DatabasePool

    func getAll(limit: Int, offset: Int, filter: SongQueryFilter) throws -> (items: [SongRecord], total: Int) {
        try db.read { db in
            var query = SongRecord.all()

            if let search = filter.search, !search.isEmpty,
               let condition = SearchHelper.buildCondition(query: search, columns: ["title", "artist", "album"]) {
                query = query.filter(condition)
            }
            if let albumId = filter.albumId {
                query = query.filter(Column("albumId") == albumId)
            }
            if let artistId = filter.artistId {
                query = query.filter(Column("artistId") == artistId)
            }
            if let genre = filter.genre, !genre.isEmpty {
                query = query.filter(Column("genre") == genre)
            }
            if filter.starredOnly == true {
                query = query.filter(Column("starredAt") != nil)
            }

            let total = try query.fetchCount(db)

            switch filter.sortBy {
            case "artist":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("artist").desc)
                    : query.order(Column("artist").asc)
            case "album":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("album").desc)
                    : query.order(Column("album").asc)
            case "starredAt":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("starredAt").desc)
                    : query.order(Column("starredAt").asc)
            case "playCount":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("playCount").desc)
                    : query.order(Column("playCount").asc)
            case "playedAt":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("playedAt").desc)
                    : query.order(Column("playedAt").asc)
            case "created":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("created").desc)
                    : query.order(Column("created").asc)
            default:
                query = filter.sortOrder == "desc"
                    ? query.order(Column("title").desc)
                    : query.order(Column("title").asc)
            }

            let items = try query.limit(limit, offset: offset).fetchAll(db)
            return (items, total)
        }
    }

    func getById(_ id: String) throws -> SongRecord? {
        try db.read { db in
            try SongRecord.fetchOne(db, key: id)
        }
    }

    func getByIds(ids: [String]) throws -> [SongRecord] {
        try db.read { db in
            try SongRecord
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
        }
    }

    func getByAlbumId(_ albumId: String) throws -> [SongRecord] {
        try db.read { db in
            try SongRecord
                .filter(Column("albumId") == albumId)
                .order(Column("discNumber").asc, Column("track").asc)
                .fetchAll(db)
        }
    }

    func upsert(_ record: SongRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func bulkUpsert(_ records: [SongRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try SongRecord.deleteAll(db)
        }
    }

    func updateStarred(ids: [String], starred: String?, starredAt: Int?) throws {
        try db.write { db in
            try SongRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db,
                    Column("starred").set(to: starred),
                    Column("starredAt").set(to: starredAt)
                )
        }
    }

    func count() throws -> Int {
        try db.read { db in
            try SongRecord.fetchCount(db)
        }
    }
}

struct SongQueryFilter {
    var search: String?
    var albumId: String?
    var artistId: String?
    var genre: String?
    var starredOnly: Bool?
    var sortBy: String?
    var sortOrder: String?
}
