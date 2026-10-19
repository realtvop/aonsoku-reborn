import Foundation
import GRDB

struct CacheMetaRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cacheMeta"

    var key: String
    var id: String
    var type: String
    var source: String
    var triggersJson: String?
    var coverSize: String?
    var sizeBytes: Int
    var cachedAt: Int
    var lastAccessedAt: Int
    var removedFromServer: Bool?

    func toDictionary() -> [String: Any?] {
        [
            "key": key,
            "id": id,
            "type": type,
            "source": source,
            "triggersJson": triggersJson,
            "coverSize": coverSize,
            "sizeBytes": sizeBytes,
            "cachedAt": cachedAt,
            "lastAccessedAt": lastAccessedAt,
            "removedFromServer": removedFromServer,
        ]
    }
}
