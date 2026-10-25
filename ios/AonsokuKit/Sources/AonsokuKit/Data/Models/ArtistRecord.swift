import Foundation
import GRDB

struct ArtistRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "artist"

    var id: String
    var name: String
    var albumCount: Int
    var coverArt: String?
    var artistImageUrl: String?
    var starred: String?
    var starredAt: Int?
    var musicBrainzId: String?
    var sortName: String?

    static let albums = hasMany(AlbumRecord.self, using: ForeignKey(["artistId"]))

    func toDictionary() -> [String: Any?] {
        [
            "id": id,
            "name": name,
            "albumCount": albumCount,
            "coverArt": coverArt,
            "artistImageUrl": artistImageUrl,
            "starred": starred,
            "starredAt": starredAt,
        ]
    }
}
