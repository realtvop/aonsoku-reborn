import Foundation
import GRDB

struct GenreRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "genre"

    var value: String
    var songCount: Int?
    var albumCount: Int?

    func toDictionary() -> [String: Any?] {
        [
            "value": value,
            "songCount": songCount,
            "albumCount": albumCount,
        ]
    }
}
