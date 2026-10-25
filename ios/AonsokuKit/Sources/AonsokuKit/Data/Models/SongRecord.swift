import Foundation
import GRDB

struct SongRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "song"

    var id: String
    var parent: String?
    var title: String
    var album: String?
    var artist: String?
    var track: Int?
    var year: Int?
    var genre: String?
    var coverArt: String?
    var size: Int?
    var contentType: String?
    var suffix: String?
    var duration: Int
    var bitRate: Int?
    var path: String?
    var playCount: Int?
    var discNumber: Int?
    var created: String?
    var albumId: String?
    var artistId: String?
    var played: String?
    var starred: String?
    var starredAt: Int?
    var playedAt: Int?
    var bpm: Int?
    var comment: String?
    var sortName: String?
    var mediaType: String?
    var musicBrainzId: String?
    var genresJson: String?
    var replayGainJson: String?

    static let albumRef = belongsTo(AlbumRecord.self, using: ForeignKey(["albumId"]))
    static let artistRef = belongsTo(ArtistRecord.self, using: ForeignKey(["artistId"]))

    func toDictionary() -> [String: Any?] {
        var dict: [String: Any?] = [
            "id": id,
            "parent": parent,
            "title": title,
            "album": album,
            "artist": artist,
            "track": track,
            "year": year,
            "genre": genre,
            "coverArt": coverArt,
            "size": size,
            "contentType": contentType,
            "suffix": suffix,
            "duration": duration,
            "bitRate": bitRate,
            "path": path,
            "playCount": playCount,
            "discNumber": discNumber,
            "created": created,
            "albumId": albumId,
            "artistId": artistId,
            "played": played,
            "starred": starred,
            "starredAt": starredAt,
            "playedAt": playedAt,
            "bpm": bpm,
            "comment": comment,
            "sortName": sortName,
            "mediaType": mediaType,
            "musicBrainzId": musicBrainzId,
        ]

        if let json = genresJson, let data = json.data(using: .utf8),
           let genres = try? JSONSerialization.jsonObject(with: data) {
            dict["genres"] = genres
        }
        if let json = replayGainJson, let data = json.data(using: .utf8),
           let rg = try? JSONSerialization.jsonObject(with: data) {
            dict["replayGain"] = rg
        }

        return dict
    }
}
