import Foundation

// MARK: - JSON Parsing

internal enum SubsonicJSON {
    // MARK: - Envelope Decoding

    /// Decodes a subsonic-response envelope and validates its status.
    static func envelope(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = json["subsonic-response"] as? [String: Any] else {
            throw SubsonicAPIError.invalidResponse("Missing subsonic-response")
        }

        let status = string(response["status"])
        guard status == "ok" else {
            let error = response["error"] as? [String: Any]
            let code = int(error?["code"]) ?? 0
            let message = string(error?["message"]) ?? "Unknown error"

            switch code {
            case 40, 41:
                throw SubsonicAPIError.authenticationFailed(message: message)
            case 50:
                throw SubsonicAPIError.notAuthorized(message: message)
            case 70:
                throw SubsonicAPIError.notFound(message: message)
            case 0 where message.lowercased().contains("not implemented") || message.lowercased().contains("unknown"):
                throw SubsonicAPIError.unsupported
            default:
                throw SubsonicAPIError.server(code: code, message: message)
            }
        }

        return response
    }

    // MARK: - Type Conversions

    /// Safely extract strings, tolerating numbers and booleans.
    static func string(_ value: Any?) -> String? {
        if let str = value as? String {
            return str.isEmpty ? nil : str
        }
        if let num = value as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    /// Safely extract integers, tolerating strings.
    static func int(_ value: Any?) -> Int? {
        if let num = value as? NSNumber {
            return num.intValue
        }
        if let str = value as? String {
            return Int(str)
        }
        return nil
    }

    /// Safely extract Int64, tolerating strings.
    static func int64(_ value: Any?) -> Int64? {
        if let num = value as? NSNumber {
            return num.int64Value
        }
        if let str = value as? String {
            return Int64(str)
        }
        return nil
    }

    /// Safely extract doubles, tolerating strings.
    static func double(_ value: Any?) -> Double? {
        if let num = value as? NSNumber {
            return num.doubleValue
        }
        if let str = value as? String {
            return Double(str)
        }
        return nil
    }

    /// Safely extract booleans, tolerating strings and numbers.
    static func bool(_ value: Any?) -> Bool {
        if let bool = value as? NSNumber {
            return bool.boolValue
        }
        if let str = value as? String {
            return str == "true" || str == "1"
        }
        if let bool = value as? Bool {
            return bool
        }
        return false
    }

    /// Parse ISO 8601 dates from Subsonic responses.
    static func date(_ value: Any?) -> Date? {
        guard var str = string(value) else { return nil }

        // Truncate fractional seconds to 3 digits (nanoseconds → milliseconds)
        if let dotIndex = str.firstIndex(of: ".") {
            let fractionalStart = str.index(after: dotIndex)
            if let zIndex = str[fractionalStart...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                let fractionalPart = str[fractionalStart..<zIndex]
                if fractionalPart.count > 3 {
                    let truncated = String(fractionalPart.prefix(3))
                    let suffix = str[zIndex...]
                    str = String(str[..<dotIndex]) + "." + truncated + suffix
                }
            }
        }

        // Try with fractional seconds first
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: str) { return date }

        // Try without fractional seconds
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: str) { return date }

        // Try date-only format (yyyy-MM-dd) and treat as UTC midnight
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(abbreviation: "UTC")
        return dateFormatter.date(from: str)
    }

    /// Extract an array from a single object or a real array.
    static func list<T>(_ value: Any?, _ mapper: (_ item: [String: Any]) -> T?) -> [T] {
        if let dict = value as? [String: Any] {
            return mapper(dict).map { [$0] } ?? []
        }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap(mapper)
        }
        return []
    }

    /// Extract array of strings.
    static func strings(_ value: Any?) -> [String] {
        if let arr = value as? [String] {
            return arr
        }
        if let arr = value as? [Any] {
            return arr.compactMap { string($0) }
        }
        if let str = string(value) {
            return [str]
        }
        return []
    }

    // MARK: - Model Parsing

    static func replayGain(_ dict: [String: Any]?) -> ReplayGainInfo? {
        guard let dict else { return nil }
        let trackGain = double(dict["trackGain"])
        let trackPeak = double(dict["trackPeak"])
        let albumGain = double(dict["albumGain"])
        let albumPeak = double(dict["albumPeak"])
        let baseGain = double(dict["baseGain"])
        let fallbackGain = double(dict["fallbackGain"])

        guard trackGain != nil || trackPeak != nil || albumGain != nil || albumPeak != nil
            || baseGain != nil || fallbackGain != nil else {
            return nil
        }

        return ReplayGainInfo(
            trackGain: trackGain,
            trackPeak: trackPeak,
            albumGain: albumGain,
            albumPeak: albumPeak,
            baseGain: baseGain,
            fallbackGain: fallbackGain
        )
    }

    static func genres(_ value: Any?) -> [String] {
        list(value) { dict in
            string(dict["name"]) ?? string(dict["value"])
        }
    }

    static func artistCredit(_ dict: [String: Any]?) -> ArtistCredit? {
        guard let dict else { return nil }
        guard let name = string(dict["name"]) ?? string(dict["artist"]) else { return nil }
        return ArtistCredit(id: string(dict["id"]), name: name)
    }

    static func artistCredits(_ value: Any?) -> [ArtistCredit] {
        list(value) { dict in
            artistCredit(dict)
        }
    }

    static func contributor(_ dict: [String: Any]?) -> Contributor? {
        guard let dict,
            let role = string(dict["role"]),
            let artist = artistCredit(dict["artist"] as? [String: Any]) else {
            return nil
        }
        return Contributor(
            role: role,
            subRole: string(dict["subRole"]),
            artist: artist
        )
    }

    static func contributors(_ value: Any?) -> [Contributor] {
        list(value) { dict in
            contributor(dict)
        }
    }

    static func explicitStatus(_ value: Any?) -> ExplicitStatus? {
        guard let str = string(value) else { return nil }
        return ExplicitStatus(rawValue: str)
    }

    static func discTitles(_ value: Any?) -> [DiscTitle] {
        list(value) { dict in
            guard let disc = int(dict["disc"]), let title = string(dict["title"]) else {
                return nil
            }
            return DiscTitle(disc: disc, title: title)
        }
    }

    static func itemDate(_ dict: [String: Any]?) -> ItemDate? {
        guard let dict else { return nil }
        let year = int(dict["year"])
        let month = int(dict["month"])
        let day = int(dict["day"])
        guard year != nil || month != nil || day != nil else { return nil }
        return ItemDate(year: year, month: month, day: day)
    }

    static func recordLabels(_ value: Any?) -> [String] {
        list(value) { dict in
            string(dict["name"])
        }
    }

    static func song(_ dict: [String: Any]?) -> Song? {
        guard let dict, let id = string(dict["id"]) else { return nil }
        return Song(
            id: id,
            parent: string(dict["parent"]),
            title: string(dict["title"]) ?? "",
            album: string(dict["album"]) ?? "",
            albumId: string(dict["albumId"]),
            artist: string(dict["artist"]) ?? "",
            artistId: string(dict["artistId"]),
            artists: artistCredits(dict["artists"]),
            displayArtist: string(dict["displayArtist"]),
            albumArtists: artistCredits(dict["albumArtists"]),
            displayAlbumArtist: string(dict["displayAlbumArtist"]),
            displayComposer: string(dict["displayComposer"]),
            contributors: contributors(dict["contributors"]),
            track: int(dict["track"]),
            discNumber: int(dict["discNumber"]),
            year: int(dict["year"]),
            genre: string(dict["genre"]),
            genres: genres(dict["genres"]),
            coverArt: string(dict["coverArt"]),
            duration: int(dict["duration"]) ?? 0,
            bitRate: int(dict["bitRate"]),
            bitDepth: int(dict["bitDepth"]),
            samplingRate: int(dict["samplingRate"]),
            channelCount: int(dict["channelCount"]),
            size: int64(dict["size"]),
            suffix: string(dict["suffix"]),
            contentType: string(dict["contentType"]),
            path: string(dict["path"]),
            playCount: int(dict["playCount"]),
            played: date(dict["played"]),
            created: date(dict["created"]),
            starred: date(dict["starred"]),
            userRating: int(dict["userRating"]),
            bpm: int(dict["bpm"]),
            comment: string(dict["comment"]),
            musicBrainzId: string(dict["musicBrainzId"]),
            replayGain: replayGain(dict["replayGain"] as? [String: Any]),
            explicitStatus: explicitStatus(dict["explicitStatus"]),
            mediaType: string(dict["mediaType"]),
            sortName: string(dict["sortName"])
        )
    }

    static func album(_ dict: [String: Any]?) -> Album? {
        guard let dict, let id = string(dict["id"]) else { return nil }
        return Album(
            id: id,
            name: string(dict["name"]) ?? "",
            artist: string(dict["artist"]) ?? "",
            artistId: string(dict["artistId"]),
            artists: artistCredits(dict["artists"]),
            displayArtist: string(dict["displayArtist"]),
            coverArt: string(dict["coverArt"]),
            songCount: int(dict["songCount"]) ?? 0,
            duration: int(dict["duration"]) ?? 0,
            playCount: int(dict["playCount"]),
            created: date(dict["created"]),
            played: date(dict["played"]),
            starred: date(dict["starred"]),
            year: int(dict["year"]),
            genre: string(dict["genre"]),
            genres: genres(dict["genres"]),
            userRating: int(dict["userRating"]),
            musicBrainzId: string(dict["musicBrainzId"]),
            isCompilation: bool(dict["isCompilation"]),
            sortName: string(dict["sortName"]),
            discTitles: discTitles(dict["discTitles"]),
            originalReleaseDate: itemDate(dict["originalReleaseDate"] as? [String: Any]),
            releaseDate: itemDate(dict["releaseDate"] as? [String: Any]),
            releaseTypes: strings(dict["releaseTypes"]),
            recordLabels: recordLabels(dict["recordLabels"]),
            moods: strings(dict["moods"]),
            explicitStatus: explicitStatus(dict["explicitStatus"])
        )
    }

    static func artist(_ dict: [String: Any]?) -> Artist? {
        guard let dict, let id = string(dict["id"]) else { return nil }
        return Artist(
            id: id,
            name: string(dict["name"]) ?? "",
            coverArt: string(dict["coverArt"]),
            artistImageUrl: string(dict["artistImageUrl"]),
            albumCount: int(dict["albumCount"]) ?? 0,
            starred: date(dict["starred"]),
            musicBrainzId: string(dict["musicBrainzId"]),
            sortName: string(dict["sortName"]),
            roles: strings(dict["roles"])
        )
    }

    static func playlist(_ dict: [String: Any]?) -> Playlist? {
        guard let dict, let id = string(dict["id"]) else { return nil }
        return Playlist(
            id: id,
            name: string(dict["name"]) ?? "",
            comment: string(dict["comment"]),
            owner: string(dict["owner"]),
            isPublic: bool(dict["public"]),
            songCount: int(dict["songCount"]) ?? 0,
            duration: int(dict["duration"]) ?? 0,
            created: date(dict["created"]),
            changed: date(dict["changed"]),
            coverArt: string(dict["coverArt"]),
            starred: date(dict["starred"])
        )
    }

    static func radioStation(_ dict: [String: Any]?) -> RadioStation? {
        guard let dict,
            let id = string(dict["id"]),
            let name = string(dict["name"]),
            let streamUrl = string(dict["streamUrl"]) else {
            return nil
        }
        let homePageUrl = string(dict["homePageUrl"]) ?? string(dict["homepageUrl"])
        return RadioStation(id: id, name: name, streamUrl: streamUrl, homePageUrl: homePageUrl)
    }

    static func user(_ dict: [String: Any]?) -> SubsonicUser? {
        guard let dict, let username = string(dict["username"]) else { return nil }
        return SubsonicUser(
            username: username,
            email: string(dict["email"]),
            scrobblingEnabled: bool(dict["scrobblingEnabled"]),
            adminRole: bool(dict["adminRole"]),
            settingsRole: bool(dict["settingsRole"]),
            downloadRole: bool(dict["downloadRole"]),
            uploadRole: bool(dict["uploadRole"]),
            playlistRole: bool(dict["playlistRole"]),
            coverArtRole: bool(dict["coverArtRole"]),
            commentRole: bool(dict["commentRole"]),
            podcastRole: bool(dict["podcastRole"]),
            streamRole: bool(dict["streamRole"]),
            jukeboxRole: bool(dict["jukeboxRole"]),
            shareRole: bool(dict["shareRole"])
        )
    }

    static func scanStatus(_ dict: [String: Any]) -> ScanStatus {
        ScanStatus(
            scanning: bool(dict["scanning"]),
            count: int(dict["count"]),
            folderCount: int(dict["folderCount"]),
            lastScan: date(dict["lastScan"])
        )
    }

    static func albumInfo(_ dict: [String: Any]) -> AlbumInfo {
        AlbumInfo(
            notes: string(dict["notes"]),
            musicBrainzId: string(dict["musicBrainzId"]),
            lastFmUrl: string(dict["lastFmUrl"]),
            smallImageUrl: string(dict["smallImageUrl"]),
            mediumImageUrl: string(dict["mediumImageUrl"]),
            largeImageUrl: string(dict["largeImageUrl"])
        )
    }

    static func artistInfo(_ dict: [String: Any]) -> ArtistInfo {
        let similarArtists = list(dict["similarArtist"]) { d in
            artist(d)
        }
        return ArtistInfo(
            biography: string(dict["biography"]),
            musicBrainzId: string(dict["musicBrainzId"]),
            lastFmUrl: string(dict["lastFmUrl"]),
            smallImageUrl: string(dict["smallImageUrl"]),
            mediumImageUrl: string(dict["mediumImageUrl"]),
            largeImageUrl: string(dict["largeImageUrl"]),
            similarArtists: similarArtists
        )
    }

    static func structuredLyrics(_ dict: [String: Any]?) -> SubsonicStructuredLyrics? {
        guard let dict else { return nil }
        let lines = list(dict["line"]) { d in
            SubsonicStructuredLyrics.Line(
                start: int(d["start"]),
                value: string(d["value"]) ?? ""
            )
        }
        return SubsonicStructuredLyrics(
            lang: string(dict["lang"]) ?? "xxx",
            synced: bool(dict["synced"]),
            offset: int(dict["offset"]) ?? 0,
            displayArtist: string(dict["displayArtist"]),
            displayTitle: string(dict["displayTitle"]),
            lines: lines
        )
    }
}
