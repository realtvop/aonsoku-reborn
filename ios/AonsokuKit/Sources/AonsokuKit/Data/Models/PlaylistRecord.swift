import Foundation
import GRDB

struct PlaylistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlist"

    var id: String
    var name: String
    var comment: String?
    var songCount: Int
    var duration: Int
    var isPublic: Bool
    var owner: String?
    var created: String?
    var changed: String?
    var coverArt: String?
    var starred: String?
    var starredAt: Int?

    func toDictionary() -> [String: Any?] {
        [
            "id": id,
            "name": name,
            "comment": comment,
            "songCount": songCount,
            "duration": duration,
            "isPublic": isPublic,
            "owner": owner,
            "created": created,
            "changed": changed,
            "coverArt": coverArt,
            "starred": starred,
            "starredAt": starredAt,
        ]
    }
}
