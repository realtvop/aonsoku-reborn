import Foundation
import GRDB

struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncState"

    var key: String
    var lastSyncedAt: Int?
    var phase: String?
    var checkpointJson: String?
}
