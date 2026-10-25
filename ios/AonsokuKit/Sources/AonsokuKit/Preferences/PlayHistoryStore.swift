import Foundation
import GRDB

final class PlayHistoryStore {
    private let db: DatabasePool
    private let now: () -> Int

    init(
        db: DatabasePool,
        now: @escaping () -> Int = {
            Int(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.db = db
        self.now = now
    }

    func history(limit: Int) throws -> [String] {
        guard limit > 0 else { return [] }
        return try db.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT songJson FROM playHistory
                    ORDER BY playedAt DESC, id DESC LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    func add(songJSON: String, maxSize: Int) throws {
        try db.write { database in
            guard maxSize > 0 else {
                try database.execute(sql: "DELETE FROM playHistory")
                return
            }
            try database.execute(
                sql: "INSERT INTO playHistory (songJson, playedAt) VALUES (?, ?)",
                arguments: [songJSON, now()]
            )
            try database.execute(
                sql: """
                    DELETE FROM playHistory WHERE id NOT IN (
                        SELECT id FROM playHistory
                        ORDER BY playedAt DESC, id DESC LIMIT ?
                    )
                    """,
                arguments: [maxSize]
            )
        }
    }

    func clear() throws {
        try db.write { database in
            try database.execute(sql: "DELETE FROM playHistory")
        }
    }
}
