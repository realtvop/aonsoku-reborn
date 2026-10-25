import Foundation
import GRDB

struct AlbumRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "album"

    var id: String
    var name: String
    var artist: String
    var artistId: String?
    var coverArt: String?
    var songCount: Int
    var duration: Int
    var year: Int?
    var genre: String?
    var created: String?
    var played: String?
    var playCount: Int?
    var starred: String?
    var starredAt: Int?

    static let songs = hasMany(SongRecord.self, using: ForeignKey(["albumId"]))
    static let artistRef = belongsTo(ArtistRecord.self, using: ForeignKey(["artistId"]))

    func toDictionary() -> [String: Any?] {
        [
            "id": id,
            "name": name,
            "artist": artist,
            "artistId": artistId,
            "coverArt": coverArt,
            "songCount": songCount,
            "duration": duration,
            "year": year,
            "genre": genre,
            "created": created,
            "played": played,
            "playCount": playCount,
            "starred": starred,
            "starredAt": starredAt,
        ]
    }
}
