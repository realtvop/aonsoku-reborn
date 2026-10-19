import Foundation
import GRDB

struct PlaybackStateRepository {
    private static let key = "current"

    let db: DatabasePool

    func save(_ state: PlaybackPersistState) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        guard let json = String(data: data, encoding: .utf8) else { return }

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO playbackState (key, stateJson, currentTime, updatedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [Self.key, json, state.currentTime, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
    }

    func saveProgress(_ currentTime: Double) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE playbackState SET currentTime = ?, updatedAt = ? WHERE key = ?
                    """,
                arguments: [currentTime, Int64(Date().timeIntervalSince1970 * 1000), Self.key]
            )
        }
    }

    func load() -> PlaybackPersistState? {
        try? db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT stateJson, currentTime FROM playbackState WHERE key = ?", arguments: [Self.key]) else {
                return nil
            }
            let json: String = row["stateJson"]
            let currentTime: Double = row["currentTime"]
            guard let data = json.data(using: .utf8) else { return nil }

            var state = try JSONDecoder().decode(PlaybackPersistState.self, from: data)
            state.currentTime = currentTime
            return state
        }
    }

    func clear() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM playbackState WHERE key = ?", arguments: [Self.key])
        }
    }
}
