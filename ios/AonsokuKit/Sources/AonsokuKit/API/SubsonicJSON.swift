import Foundation

// MARK: - Envelope Decoding

enum SubsonicJSONError: Error {
  case invalidEnvelope(String)
  case failedStatus(code: Int, message: String)
  case authenticationFailed(String)
  case notAuthorized(String)
  case notFound(String)
  case unsupported
}

/// Decodes a subsonic-response envelope and validates its status.
func decodeSubsonicEnvelope(_ data: Data) throws -> [String: Any] {
  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let response = json["subsonic-response"] as? [String: Any] else {
    throw SubsonicJSONError.invalidEnvelope("Missing subsonic-response")
  }

  let status = toString(response["status"])
  guard status == "ok" else {
    let error = response["error"] as? [String: Any]
    let code = toInt(error?["code"]) ?? 0
    let message = toString(error?["message"]) ?? "Unknown error"

    switch code {
    case 40, 41:
      throw SubsonicJSONError.authenticationFailed(message)
    case 50:
      throw SubsonicJSONError.notAuthorized(message)
    case 70:
      throw SubsonicJSONError.notFound(message)
    case 0 where message.lowercased().contains("not implemented") || message.lowercased().contains("unknown"):
      throw SubsonicJSONError.unsupported
    default:
      throw SubsonicJSONError.failedStatus(code: code, message: message)
    }
  }

  return response
}

// MARK: - Type Conversions

/// Safely extract strings, tolerating numbers and booleans.
func toString(_ value: Any?) -> String? {
  if let str = value as? String {
    return str.isEmpty ? nil : str
  }
  if let num = value as? NSNumber {
    return num.stringValue
  }
  return nil
}

/// Safely extract integers, tolerating strings.
func toInt(_ value: Any?) -> Int? {
  if let num = value as? NSNumber {
    return num.intValue
  }
  if let str = value as? String {
    return Int(str)
  }
  return nil
}

/// Safely extract Int64, tolerating strings.
func toInt64(_ value: Any?) -> Int64? {
  if let num = value as? NSNumber {
    return num.int64Value
  }
  if let str = value as? String {
    return Int64(str)
  }
  return nil
}

/// Safely extract doubles, tolerating strings.
func toDouble(_ value: Any?) -> Double? {
  if let num = value as? NSNumber {
    return num.doubleValue
  }
  if let str = value as? String {
    return Double(str)
  }
  return nil
}

/// Safely extract booleans, tolerating strings and numbers.
func toBool(_ value: Any?) -> Bool {
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
func toDate(_ value: Any?) -> Date? {
  guard let str = toString(value) else { return nil }
  let iso = ISO8601DateFormatter()
  iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = iso.date(from: str) { return date }
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  return plain.date(from: str)
}

/// Extract an array from a single object or a real array.
func toArray<T>(_ value: Any?, _ mapper: (_ item: [String: Any]) -> T?) -> [T] {
  if let dict = value as? [String: Any] {
    return mapper(dict).map { [$0] } ?? []
  }
  if let arr = value as? [[String: Any]] {
    return arr.compactMap(mapper)
  }
  return []
}

// MARK: - Model Parsing Helpers

func parseReplayGain(_ dict: [String: Any]?) -> ReplayGainInfo? {
  guard let dict else { return nil }
  let trackGain = toDouble(dict["trackGain"])
  let trackPeak = toDouble(dict["trackPeak"])
  let albumGain = toDouble(dict["albumGain"])
  let albumPeak = toDouble(dict["albumPeak"])
  let baseGain = toDouble(dict["baseGain"])
  let fallbackGain = toDouble(dict["fallbackGain"])

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

func parseGenres(_ value: Any?) -> [String] {
  toArray(value) { dict in
    toString(dict["value"])
  }
}

func parseArtistCredit(_ dict: [String: Any]?) -> ArtistCredit? {
  guard let dict else { return nil }
  guard let name = toString(dict["name"]) ?? toString(dict["artist"]) else { return nil }
  return ArtistCredit(id: toString(dict["id"]), name: name)
}

func parseArtistCredits(_ value: Any?) -> [ArtistCredit] {
  toArray(value) { dict in
    parseArtistCredit(dict)
  }
}

func parseContributor(_ dict: [String: Any]?) -> Contributor? {
  guard let dict,
        let role = toString(dict["role"]),
        let artist = parseArtistCredit(dict["artist"] as? [String: Any]) else {
    return nil
  }
  return Contributor(
    role: role,
    subRole: toString(dict["subRole"]),
    artist: artist
  )
}

func parseContributors(_ value: Any?) -> [Contributor] {
  toArray(value) { dict in
    parseContributor(dict)
  }
}

func parseExplicitStatus(_ value: Any?) -> ExplicitStatus? {
  guard let str = toString(value) else { return nil }
  return ExplicitStatus(rawValue: str)
}

func parseDiscTitles(_ value: Any?) -> [DiscTitle] {
  toArray(value) { dict in
    guard let disc = toInt(dict["disc"]), let title = toString(dict["title"]) else {
      return nil
    }
    return DiscTitle(disc: disc, title: title)
  }
}

func parseItemDate(_ dict: [String: Any]?) -> ItemDate? {
  guard let dict else { return nil }
  let year = toInt(dict["year"])
  let month = toInt(dict["month"])
  let day = toInt(dict["day"])
  guard year != nil || month != nil || day != nil else { return nil }
  return ItemDate(year: year, month: month, day: day)
}

func parseSong(_ dict: [String: Any]?) -> Song? {
  guard let dict, let id = toString(dict["id"]) else { return nil }
  return Song(
    id: id,
    parent: toString(dict["parent"]),
    title: toString(dict["title"]) ?? "",
    album: toString(dict["album"]) ?? "",
    albumId: toString(dict["albumId"]),
    artist: toString(dict["artist"]) ?? "",
    artistId: toString(dict["artistId"]),
    artists: parseArtistCredits(dict["artists"]),
    displayArtist: toString(dict["displayArtist"]),
    albumArtists: parseArtistCredits(dict["albumArtists"]),
    displayAlbumArtist: toString(dict["displayAlbumArtist"]),
    displayComposer: toString(dict["displayComposer"]),
    contributors: parseContributors(dict["contributors"]),
    track: toInt(dict["track"]),
    discNumber: toInt(dict["discNumber"]),
    year: toInt(dict["year"]),
    genre: toString(dict["genre"]),
    genres: parseGenres(dict["genres"]),
    coverArt: toString(dict["coverArt"]),
    duration: toInt(dict["duration"]) ?? 0,
    bitRate: toInt(dict["bitRate"]),
    bitDepth: toInt(dict["bitDepth"]),
    samplingRate: toInt(dict["samplingRate"]),
    channelCount: toInt(dict["channelCount"]),
    size: toInt64(dict["size"]),
    suffix: toString(dict["suffix"]),
    contentType: toString(dict["contentType"]),
    path: toString(dict["path"]),
    playCount: toInt(dict["playCount"]),
    played: toDate(dict["played"]),
    created: toDate(dict["created"]),
    starred: toDate(dict["starred"]),
    userRating: toInt(dict["userRating"]),
    bpm: toInt(dict["bpm"]),
    comment: toString(dict["comment"]),
    musicBrainzId: toString(dict["musicBrainzId"]),
    replayGain: parseReplayGain(dict["replayGain"] as? [String: Any]),
    explicitStatus: parseExplicitStatus(dict["explicitStatus"]),
    mediaType: toString(dict["mediaType"]),
    sortName: toString(dict["sortName"])
  )
}

func parseAlbum(_ dict: [String: Any]?) -> Album? {
  guard let dict, let id = toString(dict["id"]) else { return nil }
  return Album(
    id: id,
    name: toString(dict["name"]) ?? "",
    artist: toString(dict["artist"]) ?? "",
    artistId: toString(dict["artistId"]),
    artists: parseArtistCredits(dict["artists"]),
    displayArtist: toString(dict["displayArtist"]),
    coverArt: toString(dict["coverArt"]),
    songCount: toInt(dict["songCount"]) ?? 0,
    duration: toInt(dict["duration"]) ?? 0,
    playCount: toInt(dict["playCount"]),
    created: toDate(dict["created"]),
    played: toDate(dict["played"]),
    starred: toDate(dict["starred"]),
    year: toInt(dict["year"]),
    genre: toString(dict["genre"]),
    genres: parseGenres(dict["genres"]),
    userRating: toInt(dict["userRating"]),
    musicBrainzId: toString(dict["musicBrainzId"]),
    isCompilation: toBool(dict["isCompilation"]),
    sortName: toString(dict["sortName"]),
    discTitles: parseDiscTitles(dict["discTitles"]),
    originalReleaseDate: parseItemDate(dict["originalReleaseDate"] as? [String: Any]),
    releaseDate: parseItemDate(dict["releaseDate"] as? [String: Any]),
    releaseTypes: toArrayOfStrings(dict["releaseTypes"]),
    recordLabels: toArrayOfStrings(dict["recordLabels"]),
    moods: toArrayOfStrings(dict["moods"]),
    explicitStatus: parseExplicitStatus(dict["explicitStatus"])
  )
}

func parseArtist(_ dict: [String: Any]?) -> Artist? {
  guard let dict, let id = toString(dict["id"]) else { return nil }
  return Artist(
    id: id,
    name: toString(dict["name"]) ?? "",
    coverArt: toString(dict["coverArt"]),
    artistImageUrl: toString(dict["artistImageUrl"]),
    albumCount: toInt(dict["albumCount"]) ?? 0,
    starred: toDate(dict["starred"]),
    musicBrainzId: toString(dict["musicBrainzId"]),
    sortName: toString(dict["sortName"]),
    roles: toArrayOfStrings(dict["roles"])
  )
}

func parsePlaylist(_ dict: [String: Any]?) -> Playlist? {
  guard let dict, let id = toString(dict["id"]) else { return nil }
  return Playlist(
    id: id,
    name: toString(dict["name"]) ?? "",
    comment: toString(dict["comment"]),
    owner: toString(dict["owner"]),
    isPublic: toBool(dict["public"]),
    songCount: toInt(dict["songCount"]) ?? 0,
    duration: toInt(dict["duration"]) ?? 0,
    created: toDate(dict["created"]),
    changed: toDate(dict["changed"]),
    coverArt: toString(dict["coverArt"]),
    starred: toDate(dict["starred"])
  )
}

func parseRadioStation(_ dict: [String: Any]?) -> RadioStation? {
  guard let dict,
        let id = toString(dict["id"]),
        let name = toString(dict["name"]),
        let streamUrl = toString(dict["streamUrl"]) else {
    return nil
  }
  let homePageUrl = toString(dict["homePageUrl"]) ?? toString(dict["homepageUrl"])
  return RadioStation(id: id, name: name, streamUrl: streamUrl, homePageUrl: homePageUrl)
}

private func toArrayOfStrings(_ value: Any?) -> [String] {
  if let arr = value as? [String] {
    return arr
  }
  if let arr = value as? [Any] {
    return arr.compactMap { toString($0) }
  }
  if let str = toString(value) {
    return [str]
  }
  return []
}
