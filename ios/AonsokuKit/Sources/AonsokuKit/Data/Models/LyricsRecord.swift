import Foundation
import GRDB

struct LyricsRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lyrics"

    var songId: String
    var content: String
    var synced: Bool?
    var cachedAt: Int
    var lastAccessedAt: Int

    func toDictionary() -> [String: Any?] {
        [
            "songId": songId,
            "content": content,
            "synced": synced,
            "cachedAt": cachedAt,
            "lastAccessedAt": lastAccessedAt,
        ]
    }
}
