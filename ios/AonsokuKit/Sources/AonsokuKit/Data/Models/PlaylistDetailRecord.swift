import Foundation
import GRDB

struct PlaylistDetailRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlistDetail"

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
    var entriesJson: String

    func toDictionary() -> [String: Any?] {
        var dict: [String: Any?] = [
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

        if let data = entriesJson.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) {
            dict["entry"] = entries
        }

        return dict
    }
}
