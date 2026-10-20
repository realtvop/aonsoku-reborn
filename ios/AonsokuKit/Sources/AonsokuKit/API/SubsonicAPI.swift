import Foundation

// Typed Subsonic/OpenSubsonic REST access for the native app. It covers the
// endpoints the web client calls (`src/service/*.ts`). Requests go through a
// `SubsonicTransport`, which adds authentication and returns the raw JSON
// body, so the decoding in `LiveSubsonicAPI` can be tested with canned
// responses.

// MARK: - Requests

/// One REST call relative to `<server>/rest/`.
public struct SubsonicRequest: Hashable, Sendable {
    public enum Method: String, Hashable, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    /// Endpoint file name, such as `getAlbum.view`.
    public var path: String
    /// Parameters in order. Keys may repeat (`songId`, `songIdToAdd`, ...).
    public var query: [URLQueryItem]
    public var method: Method

    public init(_ path: String, query: [URLQueryItem] = [], method: Method = .get) {
        self.path = path
        self.query = query
        self.method = method
    }
}

/// Sends an authenticated request and returns the response body.
public protocol SubsonicTransport: Sendable {
    /// Throws `SubsonicAPIError.notSignedIn` without stored credentials,
    /// `.offline` or `.timedOut` for connection failures, `.http` for
    /// non-2xx status codes and `.cancelled` when the task is cancelled.
    func send(_ request: SubsonicRequest) async throws -> Data
}

/// Errors from Subsonic calls.
public enum SubsonicAPIError: Error, Equatable, Sendable, LocalizedError {
    case notSignedIn
    case offline
    case timedOut
    case cancelled
    case http(status: Int)
    /// Subsonic error 40 or 41: wrong credentials or unsupported token auth.
    case authenticationFailed(message: String)
    /// Subsonic error 50: the user lacks the role for this call.
    case notAuthorized(message: String)
    /// Subsonic error 70.
    case notFound(message: String)
    /// The server does not implement the endpoint (HTTP 404/501, or a
    /// Subsonic error for an unknown method).
    case unsupported
    /// Any other `status: "failed"` response.
    case server(code: Int, message: String)
    /// The body was not a `subsonic-response` envelope or a field had the
    /// wrong shape.
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in"
        case .offline: "The server is unreachable"
        case .timedOut: "The request timed out"
        case .cancelled: "The request was cancelled"
        case let .http(status): "HTTP \(status)"
        case let .authenticationFailed(message),
             let .notAuthorized(message),
             let .notFound(message),
             let .server(_, message),
             let .invalidResponse(message):
            message
        case .unsupported: "The server does not support this request"
        }
    }

    /// True for failures that a cached copy can stand in for.
    public var isConnectivityFailure: Bool {
        switch self {
        case .offline, .timedOut, .http: true
        default: false
        }
    }
}

// MARK: - Parameters

/// Changes for `updatePlaylist`. Nil fields stay unchanged.
public struct PlaylistChanges: Hashable, Sendable {
    public var name: String?
    public var comment: String?
    public var isPublic: Bool?
    public var songIdsToAdd: [String]
    /// Zero-based positions in the playlist before the update.
    public var songIndexesToRemove: [Int]

    public init(
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songIdsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) {
        self.name = name
        self.comment = comment
        self.isPublic = isPublic
        self.songIdsToAdd = songIdsToAdd
        self.songIndexesToRemove = songIndexesToRemove
    }

    public var isEmpty: Bool {
        name == nil && comment == nil && isPublic == nil
            && songIdsToAdd.isEmpty && songIndexesToRemove.isEmpty
    }
}

/// Items for `star` and `unstar`.
public struct StarTarget: Hashable, Sendable {
    public var songIds: [String]
    public var albumIds: [String]
    public var artistIds: [String]

    public init(songIds: [String] = [], albumIds: [String] = [], artistIds: [String] = []) {
        self.songIds = songIds
        self.albumIds = albumIds
        self.artistIds = artistIds
    }

    public static func song(_ id: String) -> StarTarget { StarTarget(songIds: [id]) }
    public static func album(_ id: String) -> StarTarget { StarTarget(albumIds: [id]) }
    public static func artist(_ id: String) -> StarTarget { StarTarget(artistIds: [id]) }
}

/// Result counts and offsets for `search3`.
public struct SearchPage: Hashable, Sendable {
    public var artistCount: Int
    public var artistOffset: Int
    public var albumCount: Int
    public var albumOffset: Int
    public var songCount: Int
    public var songOffset: Int

    public init(
        artistCount: Int = 20,
        artistOffset: Int = 0,
        albumCount: Int = 20,
        albumOffset: Int = 0,
        songCount: Int = 20,
        songOffset: Int = 0
    ) {
        self.artistCount = artistCount
        self.artistOffset = artistOffset
        self.albumCount = albumCount
        self.albumOffset = albumOffset
        self.songCount = songCount
        self.songOffset = songOffset
    }

    public static func songs(count: Int, offset: Int) -> SearchPage {
        SearchPage(artistCount: 0, albumCount: 0, songCount: count, songOffset: offset)
    }

    public static func albums(count: Int, offset: Int) -> SearchPage {
        SearchPage(artistCount: 0, albumCount: count, albumOffset: offset, songCount: 0)
    }
}

// MARK: - Lyrics payloads

/// `getLyrics` result: unsynced text, possibly containing LRC timestamps.
public struct SubsonicPlainLyrics: Hashable, Sendable {
    public var artist: String?
    public var title: String?
    public var value: String

    public init(artist: String? = nil, title: String? = nil, value: String) {
        self.artist = artist
        self.title = title
        self.value = value
    }
}

/// One `structuredLyrics` entry from OpenSubsonic `getLyricsBySongId`.
public struct SubsonicStructuredLyrics: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        /// Milliseconds; nil for unsynced lyrics.
        public var start: Int?
        public var value: String

        public init(start: Int? = nil, value: String) {
            self.start = start
            self.value = value
        }
    }

    public var lang: String
    public var synced: Bool
    /// Milliseconds to add to every line start.
    public var offset: Int
    public var displayArtist: String?
    public var displayTitle: String?
    public var lines: [Line]

    public init(
        lang: String = "xxx",
        synced: Bool,
        offset: Int = 0,
        displayArtist: String? = nil,
        displayTitle: String? = nil,
        lines: [Line]
    ) {
        self.lang = lang
        self.synced = synced
        self.offset = offset
        self.displayArtist = displayArtist
        self.displayTitle = displayTitle
        self.lines = lines
    }
}

// MARK: - API

/// The Subsonic calls the app makes. Every method throws `SubsonicAPIError`.
public protocol SubsonicAPI: Sendable {
    // System
    /// `ping`, with what the envelope says about the server.
    func ping() async throws -> ServerInfo
    func user(username: String) async throws -> SubsonicUser
    func scanStatus() async throws -> ScanStatus
    func startScan() async throws -> ScanStatus

    // Browsing
    /// `getAlbumList2`. `fromYear`/`toYear` apply to `.byYear`, `genre` to
    /// `.byGenre`.
    func albumList(
        _ type: AlbumListType,
        size: Int,
        offset: Int,
        fromYear: Int?,
        toYear: Int?,
        genre: String?
    ) async throws -> [Album]
    func album(id: String) async throws -> AlbumDetail
    func albumInfo(id: String) async throws -> AlbumInfo
    /// `getArtists`, flattened across index letters in server order.
    func artists() async throws -> [Artist]
    func artist(id: String) async throws -> ArtistDetail
    func artistInfo(id: String) async throws -> ArtistInfo
    /// `getTopSongs` by artist name.
    func topSongs(artistName: String, count: Int) async throws -> [Song]
    func song(id: String) async throws -> Song
    func randomSongs(size: Int, genre: String?, fromYear: Int?, toYear: Int?) async throws -> [Song]
    func genres() async throws -> [Genre]
    /// `getStarred2`.
    func starred() async throws -> SearchResults
    /// `search3`. An empty query lists everything on Navidrome.
    func search(_ query: String, page: SearchPage) async throws -> SearchResults

    // Playlists
    func playlists() async throws -> [Playlist]
    func playlist(id: String) async throws -> PlaylistDetail
    /// Returns the new playlist when the server sends it back (1.14+).
    func createPlaylist(name: String, songIds: [String]) async throws -> PlaylistDetail?
    func updatePlaylist(id: String, changes: PlaylistChanges) async throws
    func deletePlaylist(id: String) async throws

    // Annotation
    func star(_ target: StarTarget) async throws
    func unstar(_ target: StarTarget) async throws
    func scrobble(songId: String, submission: Bool, time: Date?) async throws

    // Internet radio
    func radioStations() async throws -> [RadioStation]
    func createRadioStation(name: String, streamUrl: String, homePageUrl: String?) async throws
    func updateRadioStation(_ station: RadioStation) async throws
    func deleteRadioStation(id: String) async throws

    // Lyrics
    /// `getLyrics`; nil when the server has none.
    func lyrics(artist: String, title: String) async throws -> SubsonicPlainLyrics?
    /// OpenSubsonic `getLyricsBySongId`; empty when the server has none.
    /// Throws `.unsupported` on servers without the extension.
    func lyricsBySongId(_ id: String) async throws -> [SubsonicStructuredLyrics]
}

// MARK: - Live implementation

/// Decodes `subsonic-response` envelopes from a transport.
public struct LiveSubsonicAPI: SubsonicAPI {
    private let transport: SubsonicTransport

    public init(transport: SubsonicTransport = AuthenticatedSubsonicTransport()) {
        self.transport = transport
    }

    private func decodeEnvelope(_ data: Data) throws -> [String: Any] {
        do {
            return try SubsonicJSON.envelope(data)
        } catch SubsonicAPIError.http(let status) where status == 404 || status == 501 {
            throw SubsonicAPIError.unsupported
        }
    }

    public func ping() async throws -> ServerInfo {
        let data = try await transport.send(SubsonicRequest("ping.view"))
        let response = try decodeEnvelope(data)
        let type = SubsonicJSON.string(response["type"]) ?? "subsonic"
        let serverVersion = SubsonicJSON.string(response["serverVersion"])
        let protocolVersion = SubsonicJSON.string(response["version"]) ?? "1.16.1"
        let isOpenSubsonic = SubsonicJSON.bool(response["openSubsonic"])
        return ServerInfo(
            type: type,
            serverVersion: serverVersion,
            protocolVersion: protocolVersion,
            isOpenSubsonic: isOpenSubsonic
        )
    }

    public func user(username: String) async throws -> SubsonicUser {
        let request = SubsonicRequest(
            "getUser.view",
            query: [URLQueryItem(name: "username", value: username)]
        )
        let data = try await transport.send(request)
        let response = try decodeEnvelope(data)
        let user = response["user"] as? [String: Any] ?? [:]
        return SubsonicJSON.user(user) ?? SubsonicUser(username: username)
    }

    public func scanStatus() async throws -> ScanStatus {
        let data = try await transport.send(SubsonicRequest("getScanStatus.view"))
        let response = try decodeEnvelope(data)
        let status = response["scanStatus"] as? [String: Any] ?? [:]
        return SubsonicJSON.scanStatus(status)
    }

    public func startScan() async throws -> ScanStatus {
        let data = try await transport.send(SubsonicRequest("startScan.view"))
        let response = try decodeEnvelope(data)
        let status = response["scanStatus"] as? [String: Any] ?? [:]
        return SubsonicJSON.scanStatus(status)
    }

    public func albumList(
        _ type: AlbumListType,
        size: Int,
        offset: Int,
        fromYear: Int?,
        toYear: Int?,
        genre: String?
    ) async throws -> [Album] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        if type == .byYear {
            if let fromYear {
                query.append(URLQueryItem(name: "fromYear", value: String(fromYear)))
            }
            if let toYear {
                query.append(URLQueryItem(name: "toYear", value: String(toYear)))
            }
        }
        if type == .byGenre, let genre {
            query.append(URLQueryItem(name: "genre", value: genre))
        }

        let data = try await transport.send(SubsonicRequest("getAlbumList2.view", query: query))
        let response = try decodeEnvelope(data)
        let list = response["albumList2"] as? [String: Any] ?? [:]
        return SubsonicJSON.list(list["album"]) { dict in
            SubsonicJSON.album(dict)
        }
    }

    public func album(id: String) async throws -> AlbumDetail {
        let data = try await transport.send(
            SubsonicRequest("getAlbum.view", query: [URLQueryItem(name: "id", value: id)])
        )
        let response = try decodeEnvelope(data)
        let albumDict = response["album"] as? [String: Any] ?? [:]
        guard let album = SubsonicJSON.album(albumDict) else {
            throw SubsonicAPIError.invalidResponse("Missing album")
        }
        let songs = SubsonicJSON.list(albumDict["song"]) { dict in
            SubsonicJSON.song(dict)
        }
        return AlbumDetail(album: album, songs: songs)
    }

    public func albumInfo(id: String) async throws -> AlbumInfo {
        let data = try await transport.send(
            SubsonicRequest("getAlbumInfo2.view", query: [URLQueryItem(name: "id", value: id)])
        )
        let response = try decodeEnvelope(data)
        let info = response["albumInfo"] as? [String: Any] ?? [:]
        return SubsonicJSON.albumInfo(info)
    }

    public func artists() async throws -> [Artist] {
        let data = try await transport.send(SubsonicRequest("getArtists.view"))
        let response = try decodeEnvelope(data)
        let artists = response["artists"] as? [String: Any] ?? [:]
        let indices = artists["index"] as? [[String: Any]] ?? []
        var result: [Artist] = []
        for indexDict in indices {
            let artistsInIndex = SubsonicJSON.list(indexDict["artist"]) { dict in
                SubsonicJSON.artist(dict)
            }
            result.append(contentsOf: artistsInIndex)
        }
        return result
    }

    public func artist(id: String) async throws -> ArtistDetail {
        let data = try await transport.send(
            SubsonicRequest("getArtist.view", query: [URLQueryItem(name: "id", value: id)])
        )
        let response = try decodeEnvelope(data)
        let artistDict = response["artist"] as? [String: Any] ?? [:]
        guard let artist = SubsonicJSON.artist(artistDict) else {
            throw SubsonicAPIError.invalidResponse("Missing artist")
        }
        let albums = SubsonicJSON.list(artistDict["album"]) { dict in
            SubsonicJSON.album(dict)
        }
        return ArtistDetail(artist: artist, albums: albums)
    }

    public func artistInfo(id: String) async throws -> ArtistInfo {
        let data = try await transport.send(
            SubsonicRequest("getArtistInfo.view", query: [URLQueryItem(name: "id", value: id)])
        )
        let response = try decodeEnvelope(data)
        let info = response["artistInfo2"] as? [String: Any] ?? response["artistInfo"] as? [String: Any] ?? [:]
        return SubsonicJSON.artistInfo(info)
    }

    public func topSongs(artistName: String, count: Int) async throws -> [Song] {
        let query = [
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "count", value: String(count))
        ]
        let data = try await transport.send(SubsonicRequest("getTopSongs.view", query: query))
        let response = try decodeEnvelope(data)
        let topSongs = response["topSongs"] as? [String: Any] ?? [:]
        return SubsonicJSON.list(topSongs["song"]) { dict in
            SubsonicJSON.song(dict)
        }
    }

    public func song(id: String) async throws -> Song {
        let data = try await transport.send(
            SubsonicRequest("getSong.view", query: [URLQueryItem(name: "id", value: id)])
        )
        let response = try decodeEnvelope(data)
        let songDict = response["song"] as? [String: Any] ?? [:]
        guard let song = SubsonicJSON.song(songDict) else {
            throw SubsonicAPIError.invalidResponse("Missing song")
        }
        return song
    }

    public func randomSongs(
        size: Int,
        genre: String?,
        fromYear: Int?,
        toYear: Int?
    ) async throws -> [Song] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "size", value: String(size))
        ]
        if let genre {
            query.append(URLQueryItem(name: "genre", value: genre))
        }
        if let fromYear {
            query.append(URLQueryItem(name: "fromYear", value: String(fromYear)))
        }
        if let toYear {
            query.append(URLQueryItem(name: "toYear", value: String(toYear)))
        }

        let data = try await transport.send(SubsonicRequest("getRandomSongs.view", query: query))
        let response = try decodeEnvelope(data)
        let randomSongs = response["randomSongs"] as? [String: Any] ?? [:]
        return SubsonicJSON.list(randomSongs["song"]) { dict in
            SubsonicJSON.song(dict)
        }
    }

    public func genres() async throws -> [Genre] {
        let data = try await transport.send(SubsonicRequest("getGenres.view"))
        let response = try decodeEnvelope(data)
        let genres = response["genres"] as? [String: Any] ?? [:]
        return SubsonicJSON.list(genres["genre"]) { dict in
            guard let name = SubsonicJSON.string(dict["value"]) else { return nil }
            return Genre(
                name: name,
                songCount: SubsonicJSON.int(dict["songCount"]) ?? 0,
                albumCount: SubsonicJSON.int(dict["albumCount"]) ?? 0
            )
        }
    }

    public func starred() async throws -> SearchResults {
        let data = try await transport.send(SubsonicRequest("getStarred2.view"))
        let response = try decodeEnvelope(data)
        let starred = response["starred2"] as? [String: Any] ?? [:]
        let artists = SubsonicJSON.list(starred["artist"]) { dict in
            SubsonicJSON.artist(dict)
        }
        let albums = SubsonicJSON.list(starred["album"]) { dict in
            SubsonicJSON.album(dict)
        }
        let songs = SubsonicJSON.list(starred["song"]) { dict in
            SubsonicJSON.song(dict)
        }
        return SearchResults(artists: artists, albums: albums, songs: songs)
    }

    public func search(_ query: String, page: SearchPage) async throws -> SearchResults {
        let queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: String(page.artistCount)),
            URLQueryItem(name: "artistOffset", value: String(page.artistOffset)),
            URLQueryItem(name: "albumCount", value: String(page.albumCount)),
            URLQueryItem(name: "albumOffset", value: String(page.albumOffset)),
            URLQueryItem(name: "songCount", value: String(page.songCount)),
            URLQueryItem(name: "songOffset", value: String(page.songOffset))
        ]
        let data = try await transport.send(SubsonicRequest("search3.view", query: queryItems))
        let response = try decodeEnvelope(data)
        let result = response["searchResult3"] as? [String: Any] ?? [:]
        let artists = SubsonicJSON.list(result["artist"]) { dict in
            SubsonicJSON.artist(dict)
        }
        let albums = SubsonicJSON.list(result["album"]) { dict in
            SubsonicJSON.album(dict)
        }
        let songs = SubsonicJSON.list(result["song"]) { dict in
            SubsonicJSON.song(dict)
        }
        return SearchResults(artists: artists, albums: albums, songs: songs)
    }

    public func playlists() async throws -> [Playlist] {
        let data = try await transport.send(SubsonicRequest("getPlaylists.view"))
        let response = try decodeEnvelope(data)
        let playlists = response["playlists"] as? [String: Any] ?? [:]
        return SubsonicJSON.list(playlists["playlist"]) { dict in
            SubsonicJSON.playlist(dict)
        }
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        let data = try await transport.send(
            SubsonicRequest("getPlaylist.view", query: [URLQueryItem(name: "id", value: id)])
        )
        let response = try decodeEnvelope(data)
        let playlistDict = response["playlist"] as? [String: Any] ?? [:]
        guard let playlist = SubsonicJSON.playlist(playlistDict) else {
            throw SubsonicAPIError.invalidResponse("Missing playlist")
        }
        let songs = SubsonicJSON.list(playlistDict["entry"]) { dict in
            SubsonicJSON.song(dict)
        }
        return PlaylistDetail(playlist: playlist, songs: songs)
    }

    public func createPlaylist(name: String, songIds: [String]) async throws -> PlaylistDetail? {
        var query = [URLQueryItem(name: "name", value: name)]
        for songId in songIds {
            query.append(URLQueryItem(name: "songId", value: songId))
        }
        let data = try await transport.send(
            SubsonicRequest("createPlaylist.view", query: query)
        )
        let response = try decodeEnvelope(data)
        let playlistDict = response["playlist"] as? [String: Any]
        guard let playlistDict, let playlist = SubsonicJSON.playlist(playlistDict) else {
            return nil
        }
        let songs = SubsonicJSON.list(playlistDict["entry"]) { dict in
            SubsonicJSON.song(dict)
        }
        return PlaylistDetail(playlist: playlist, songs: songs)
    }

    public func updatePlaylist(id: String, changes: PlaylistChanges) async throws {
        guard !changes.isEmpty else { return }

        var query = [URLQueryItem(name: "playlistId", value: id)]
        if let name = changes.name {
            query.append(URLQueryItem(name: "name", value: name))
        }
        if let comment = changes.comment {
            query.append(URLQueryItem(name: "comment", value: comment))
        }
        if let isPublic = changes.isPublic {
            query.append(URLQueryItem(name: "public", value: isPublic ? "true" : "false"))
        }
        for songId in changes.songIdsToAdd {
            query.append(URLQueryItem(name: "songIdToAdd", value: songId))
        }
        for index in changes.songIndexesToRemove {
            query.append(URLQueryItem(name: "songIndexToRemove", value: String(index)))
        }

        _ = try await transport.send(SubsonicRequest("updatePlaylist.view", query: query))
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await transport.send(
            SubsonicRequest("deletePlaylist.view", query: [URLQueryItem(name: "id", value: id)])
        )
    }

    public func star(_ target: StarTarget) async throws {
        guard !target.songIds.isEmpty || !target.albumIds.isEmpty || !target.artistIds.isEmpty
        else { return }

        var query: [URLQueryItem] = []
        for songId in target.songIds {
            query.append(URLQueryItem(name: "id", value: songId))
        }
        for albumId in target.albumIds {
            query.append(URLQueryItem(name: "albumId", value: albumId))
        }
        for artistId in target.artistIds {
            query.append(URLQueryItem(name: "artistId", value: artistId))
        }

        _ = try await transport.send(SubsonicRequest("star.view", query: query))
    }

    public func unstar(_ target: StarTarget) async throws {
        guard !target.songIds.isEmpty || !target.albumIds.isEmpty || !target.artistIds.isEmpty
        else { return }

        var query: [URLQueryItem] = []
        for songId in target.songIds {
            query.append(URLQueryItem(name: "id", value: songId))
        }
        for albumId in target.albumIds {
            query.append(URLQueryItem(name: "albumId", value: albumId))
        }
        for artistId in target.artistIds {
            query.append(URLQueryItem(name: "artistId", value: artistId))
        }

        _ = try await transport.send(SubsonicRequest("unstar.view", query: query))
    }

    public func scrobble(songId: String, submission: Bool, time: Date?) async throws {
        var query = [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "submission", value: submission ? "true" : "false")
        ]
        if let time {
            let milliseconds = Int64(time.timeIntervalSince1970 * 1000)
            query.append(URLQueryItem(name: "time", value: String(milliseconds)))
        }

        _ = try await transport.send(SubsonicRequest("scrobble.view", query: query))
    }

    public func radioStations() async throws -> [RadioStation] {
        let data = try await transport.send(SubsonicRequest("getInternetRadioStations.view"))
        let response = try decodeEnvelope(data)
        let stations = response["internetRadioStations"] as? [String: Any] ?? [:]
        return SubsonicJSON.list(stations["internetRadioStation"]) { dict in
            SubsonicJSON.radioStation(dict)
        }
    }

    public func createRadioStation(
        name: String,
        streamUrl: String,
        homePageUrl: String?
    ) async throws {
        var query = [
            URLQueryItem(name: "streamUrl", value: streamUrl),
            URLQueryItem(name: "name", value: name)
        ]
        if let homePageUrl {
            query.append(URLQueryItem(name: "homepageUrl", value: homePageUrl))
        }

        _ = try await transport.send(
            SubsonicRequest("createInternetRadioStation.view", query: query, method: .post)
        )
    }

    public func updateRadioStation(_ station: RadioStation) async throws {
        let query = [
            URLQueryItem(name: "id", value: station.id),
            URLQueryItem(name: "streamUrl", value: station.streamUrl),
            URLQueryItem(name: "name", value: station.name),
            URLQueryItem(name: "homepageUrl", value: station.homePageUrl ?? "")
        ]

        _ = try await transport.send(
            SubsonicRequest("updateInternetRadioStation.view", query: query)
        )
    }

    public func deleteRadioStation(id: String) async throws {
        _ = try await transport.send(
            SubsonicRequest("deleteInternetRadioStation.view", query: [URLQueryItem(name: "id", value: id)])
        )
    }

    public func lyrics(artist: String, title: String) async throws -> SubsonicPlainLyrics? {
        let query = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title)
        ]
        let data = try await transport.send(SubsonicRequest("getLyrics.view", query: query))
        let response = try decodeEnvelope(data)
        let lyrics = response["lyrics"] as? [String: Any]
        guard let lyrics, !lyrics.isEmpty else { return nil }

        let value = SubsonicJSON.string(lyrics["value"]) ?? ""
        guard !value.isEmpty else { return nil }

        return SubsonicPlainLyrics(
            artist: SubsonicJSON.string(lyrics["artist"]),
            title: SubsonicJSON.string(lyrics["title"]),
            value: value
        )
    }

    public func lyricsBySongId(_ id: String) async throws -> [SubsonicStructuredLyrics] {
        let data = try await transport.send(
            SubsonicRequest("getLyricsBySongId.view", query: [URLQueryItem(name: "id", value: id)])
        )

        do {
            let response = try decodeEnvelope(data)
            let lyricsList = response["lyricsList"] as? [String: Any] ?? [:]
            return SubsonicJSON.list(lyricsList["structuredLyrics"]) { dict in
                SubsonicJSON.structuredLyrics(dict)
            }
        }
    }
}

/// Signs requests with the stored credentials through
/// `AuthenticationService.url(path:query:)` and appends repeated parameters.
public struct AuthenticatedSubsonicTransport: SubsonicTransport {
    private let authentication: AuthenticationService
    private let session: URLSession
    private let urlBuilder: @Sendable (String) -> URL?

    public init(authentication: AuthenticationService = .shared, session: URLSession = .shared) {
        self.authentication = authentication
        self.session = session
        self.urlBuilder = { path in authentication.url(path: path) }
    }

    internal init(
        urlBuilder: @escaping @Sendable (String) -> URL?,
        session: URLSession
    ) {
        self.authentication = .shared
        self.session = session
        self.urlBuilder = urlBuilder
    }

    public func send(_ request: SubsonicRequest) async throws -> Data {
        guard let baseURL = urlBuilder(request.path) else {
            throw SubsonicAPIError.notSignedIn
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        ?? URLComponents()

        let percentEncodedItems = components.percentEncodedQueryItems ?? []
        var allItems = percentEncodedItems

        for item in request.query {
            if let value = item.value {
                let encoded = percentEncode(value)
                allItems.append(URLQueryItem(name: item.name, value: encoded))
            }
        }

        components.percentEncodedQueryItems = allItems

        guard let url = components.url else {
            throw SubsonicAPIError.offline
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SubsonicAPIError.offline
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 404 || httpResponse.statusCode == 501 {
                    throw SubsonicAPIError.unsupported
                }
                throw SubsonicAPIError.http(status: httpResponse.statusCode)
            }

            return data
        } catch is CancellationError {
            throw SubsonicAPIError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw SubsonicAPIError.cancelled
            case .timedOut:
                throw SubsonicAPIError.timedOut
            default:
                throw SubsonicAPIError.offline
            }
        } catch let error as SubsonicAPIError {
            throw error
        } catch {
            throw SubsonicAPIError.offline
        }
    }

    private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+=&")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
