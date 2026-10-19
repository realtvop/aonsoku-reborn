import Foundation
import GRDB

struct AlbumRepository {
    let db: DatabasePool

    func getAll(limit: Int, offset: Int, filter: AlbumQueryFilter) throws -> (items: [AlbumRecord], total: Int) {
        try db.read { db in
            var query = AlbumRecord.all()

            if let search = filter.search, !search.isEmpty,
               let condition = SearchHelper.buildCondition(query: search, columns: ["name", "artist"]) {
                query = query.filter(condition)
            }
            if let artistId = filter.artistId {
                query = query.filter(Column("artistId") == artistId)
            }
            if let genre = filter.genre, !genre.isEmpty {
                query = query.filter(Column("genre") == genre)
            }
            if let fromYear = filter.fromYear {
                query = query.filter(Column("year") >= fromYear)
            }
            if let toYear = filter.toYear {
                query = query.filter(Column("year") <= toYear)
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
            case "year":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("year").desc)
                    : query.order(Column("year").asc)
            case "created":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("created").desc)
                    : query.order(Column("created").asc)
            case "starredAt":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("starredAt").desc)
                    : query.order(Column("starredAt").asc)
            case "playCount":
                query = filter.sortOrder == "desc"
                    ? query.order(Column("playCount").desc)
                    : query.order(Column("playCount").asc)
            case "random":
                query = query.order(sql: "RANDOM()")
            default:
                query = filter.sortOrder == "desc"
                    ? query.order(Column("name").desc)
                    : query.order(Column("name").asc)
            }

            let items = try query.limit(limit, offset: offset).fetchAll(db)
            return (items, total)
        }
    }

    func getById(_ id: String) throws -> AlbumRecord? {
        try db.read { db in
            try AlbumRecord.fetchOne(db, key: id)
        }
    }

    func getWithSongs(_ id: String) throws -> (album: AlbumRecord, songs: [SongRecord])? {
        try db.read { db in
            guard let album = try AlbumRecord.fetchOne(db, key: id) else { return nil }
            let songs = try SongRecord
                .filter(Column("albumId") == id)
                .order(Column("discNumber").asc, Column("track").asc)
                .fetchAll(db)
            return (album, songs)
        }
    }

    func upsert(_ record: AlbumRecord) throws {
        try db.write { db in
            try record.save(db, onConflict: .replace)
        }
    }

    func bulkUpsert(_ records: [AlbumRecord]) throws {
        try db.write { db in
            for record in records {
                try record.save(db, onConflict: .replace)
            }
        }
    }

    func deleteAll() throws {
        try db.write { db in
            _ = try AlbumRecord.deleteAll(db)
        }
    }

    func count() throws -> Int {
        try db.read { db in
            try AlbumRecord.fetchCount(db)
        }
    }
}

struct AlbumQueryFilter {
    var search: String?
    var artistId: String?
    var genre: String?
    var fromYear: Int?
    var toYear: Int?
    var starredOnly: Bool?
    var sortBy: String?
    var sortOrder: String?
}
