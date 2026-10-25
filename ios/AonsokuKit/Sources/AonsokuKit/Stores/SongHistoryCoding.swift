import Foundation

extension Song {
    /// Encodes the same Subsonic song shape that `SubsonicJSON.song` reads.
    func playHistoryJSON() throws -> String {
        var object: [String: Any] = [
            "id": id,
            "title": title,
            "album": album,
            "artist": artist,
            "duration": duration,
            "artists": artists.map { $0.historyJSONObject },
            "albumArtists": albumArtists.map { $0.historyJSONObject },
            "contributors": contributors.map { $0.historyJSONObject },
            "genres": genres.map { ["name": $0] },
        ]
        object.put(parent, at: "parent")
        object.put(albumId, at: "albumId")
        object.put(artistId, at: "artistId")
        object.put(displayArtist, at: "displayArtist")
        object.put(displayAlbumArtist, at: "displayAlbumArtist")
        object.put(displayComposer, at: "displayComposer")
        object.put(track, at: "track")
        object.put(discNumber, at: "discNumber")
        object.put(year, at: "year")
        object.put(genre, at: "genre")
        object.put(coverArt, at: "coverArt")
        object.put(bitRate, at: "bitRate")
        object.put(bitDepth, at: "bitDepth")
        object.put(samplingRate, at: "samplingRate")
        object.put(channelCount, at: "channelCount")
        object.put(size, at: "size")
        object.put(suffix, at: "suffix")
        object.put(contentType, at: "contentType")
        object.put(path, at: "path")
        object.put(playCount, at: "playCount")
        object.put(played?.subsonicTimestamp, at: "played")
        object.put(created?.subsonicTimestamp, at: "created")
        object.put(starred?.subsonicTimestamp, at: "starred")
        object.put(userRating, at: "userRating")
        object.put(bpm, at: "bpm")
        object.put(comment, at: "comment")
        object.put(musicBrainzId, at: "musicBrainzId")
        object.put(replayGain?.historyJSONObject, at: "replayGain")
        object.put(explicitStatus?.rawValue, at: "explicitStatus")
        object.put(mediaType, at: "mediaType")
        object.put(sortName, at: "sortName")
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return value
    }
}

private extension ArtistCredit {
    var historyJSONObject: [String: Any] {
        var result: [String: Any] = ["name": name]
        result.put(id, at: "id")
        return result
    }
}

private extension Contributor {
    var historyJSONObject: [String: Any] {
        var result: [String: Any] = [
            "role": role,
            "artist": artist.historyJSONObject,
        ]
        result.put(subRole, at: "subRole")
        return result
    }
}

private extension ReplayGainInfo {
    var historyJSONObject: [String: Any] {
        var result: [String: Any] = [:]
        result.put(trackGain, at: "trackGain")
        result.put(trackPeak, at: "trackPeak")
        result.put(albumGain, at: "albumGain")
        result.put(albumPeak, at: "albumPeak")
        result.put(baseGain, at: "baseGain")
        result.put(fallbackGain, at: "fallbackGain")
        return result
    }
}

private extension Dictionary where Key == String, Value == Any {
    mutating func put<T>(_ value: T?, at key: String) {
        if let value { self[key] = value }
    }
}

private extension Date {
    var subsonicTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}
