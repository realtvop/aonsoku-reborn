import Foundation

extension LibraryArtist {
    var mediaValue: Artist {
        Artist(
            id: id,
            name: name,
            coverArt: coverArt,
            artistImageUrl: artistImageUrl,
            albumCount: albumCount,
            starred: StoredMediaValue.date(starred, milliseconds: starredAt),
            musicBrainzId: musicBrainzId,
            sortName: sortName
        )
    }
}

extension LibraryAlbum {
    var mediaValue: Album {
        Album(
            id: id,
            name: name,
            artist: artist,
            artistId: artistId,
            coverArt: coverArt,
            songCount: songCount,
            duration: duration,
            playCount: playCount,
            created: StoredMediaValue.date(created),
            played: StoredMediaValue.date(played),
            starred: StoredMediaValue.date(starred, milliseconds: starredAt),
            year: year,
            genre: genre,
            genres: genre.map { [$0] } ?? []
        )
    }
}

extension LibrarySong {
    var mediaValue: Song {
        Song(
            id: id,
            parent: parent,
            title: title,
            album: album ?? "",
            albumId: albumId,
            artist: artist ?? "",
            artistId: artistId,
            track: track,
            discNumber: discNumber,
            year: year,
            genre: genre,
            genres: StoredMediaValue.genres(genresJSON, fallback: genre),
            coverArt: coverArt,
            duration: duration,
            bitRate: bitRate,
            size: size.map(Int64.init),
            suffix: suffix,
            contentType: contentType,
            path: path,
            playCount: playCount,
            played: StoredMediaValue.date(played, milliseconds: playedAt),
            created: StoredMediaValue.date(created),
            starred: StoredMediaValue.date(starred, milliseconds: starredAt),
            bpm: bpm,
            comment: comment,
            musicBrainzId: musicBrainzId,
            replayGain: StoredMediaValue.replayGain(replayGainJSON),
            mediaType: mediaType,
            sortName: sortName
        )
    }
}

extension LibraryPlaylist {
    var mediaValue: Playlist {
        Playlist(
            id: id,
            name: name,
            comment: comment,
            owner: owner,
            isPublic: isPublic,
            songCount: songCount,
            duration: duration,
            created: StoredMediaValue.date(created),
            changed: StoredMediaValue.date(changed),
            coverArt: coverArt,
            starred: StoredMediaValue.date(starred, milliseconds: starredAt)
        )
    }
}

extension LibraryPlaylistDetail {
    var mediaValue: PlaylistDetail {
        PlaylistDetail(
            playlist: playlist.mediaValue,
            songs: StoredMediaValue.songs(entriesJSON)
        )
    }
}

extension LibraryGenre {
    var mediaValue: Genre {
        Genre(
            name: value,
            songCount: songCount ?? 0,
            albumCount: albumCount ?? 0
        )
    }
}

private enum StoredMediaValue {
    static func date(_ value: String?, milliseconds: Int? = nil) -> Date? {
        if let value {
            if let numeric = Double(value) {
                return numericDate(numeric)
            }
            if let parsed = SubsonicJSON.date(value) {
                return parsed
            }
        }
        return milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    static func genres(_ json: String?, fallback: String?) -> [String] {
        guard let value = jsonValue(json) else {
            return fallback.map { [$0] } ?? []
        }
        if let strings = value as? [String] {
            return strings.filter { !$0.isEmpty }
        }
        let parsed = SubsonicJSON.genres(value)
        return parsed.isEmpty ? (fallback.map { [$0] } ?? []) : parsed
    }

    static func replayGain(_ json: String?) -> ReplayGainInfo? {
        SubsonicJSON.replayGain(jsonValue(json) as? [String: Any])
    }

    static func songs(_ json: String) -> [Song] {
        guard let value = jsonValue(json) else { return [] }
        return SubsonicJSON.list(value) { SubsonicJSON.song($0) }
    }

    private static func numericDate(_ value: Double) -> Date {
        let seconds = abs(value) >= 100_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func jsonValue(_ value: String?) -> Any? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
