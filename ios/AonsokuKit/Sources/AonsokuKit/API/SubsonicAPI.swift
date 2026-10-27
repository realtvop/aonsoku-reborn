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

extension SubsonicAPIError {
    /// Maps a failure from a transport or `URLSession` to an API error.
    init(mapping error: any Error) {
        switch error {
        case let error as SubsonicAPIError:
            self = error
        case is CancellationError:
            self = .cancelled
        case let error as URLError:
            switch error.code {
            case .cancelled: self = .cancelled
            case .timedOut: self = .timedOut
            default: self = .offline
            }
        default:
            self = .invalidResponse(error.localizedDescription)
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
    /// `getSongsByGenre`: one page of the songs in a genre.
    func songsByGenre(_ genre: String, count: Int, offset: Int) async throws -> [Song]
    func genres() async throws -> [Genre]
    /// `getStarred2`.
    func starred() async throws -> SearchResults
    /// `search3`. The query is sent as is: to list everything, Navidrome
    /// needs `""` (two double quotes) and other servers an empty string.
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

    /// Sends one call and returns its validated `subsonic-response` object.
    /// Every endpoint goes through here, writes included, so a `failed`
    /// status throws instead of passing as success.
    @discardableResult
    private func send(
        _ path: String,
        _ query: [URLQueryItem] = [],
        method: SubsonicRequest.Method = .get
    ) async throws -> [String: Any] {
        let data: Data
        do {
            data = try await transport.send(SubsonicRequest(path, query: query, method: method))
        } catch {
            switch SubsonicAPIError(mapping: error) {
            case let .http(status) where status == 404 || status == 501:
                throw SubsonicAPIError.unsupported
            case let mapped:
                throw mapped
            }
        }
        return try SubsonicJSON.envelope(data)
    }

    // MARK: System

    public func ping() async throws -> ServerInfo {
        let response = try await send("ping.view")
        return ServerInfo(
            type: SubsonicJSON.string(response["type"]) ?? "subsonic",
            serverVersion: SubsonicJSON.string(response["serverVersion"]),
            protocolVersion: SubsonicJSON.string(response["version"]) ?? "1.16.1",
            isOpenSubsonic: SubsonicJSON.bool(response["openSubsonic"])
        )
    }

    public func user(username: String) async throws -> SubsonicUser {
        let response = try await send(
            "getUser.view",
            [URLQueryItem(name: "username", value: username)]
        )
        guard let user = SubsonicJSON.user(response["user"] as? [String: Any]) else {
            throw SubsonicAPIError.invalidResponse("Missing user")
        }
        return user
    }

    public func scanStatus() async throws -> ScanStatus {
        let response = try await send("getScanStatus.view")
        return SubsonicJSON.scanStatus(SubsonicJSON.object(response["scanStatus"]))
    }

    public func startScan() async throws -> ScanStatus {
        let response = try await send("startScan.view")
        return SubsonicJSON.scanStatus(SubsonicJSON.object(response["scanStatus"]))
    }

    // MARK: Browsing

    public func albumList(
        _ type: AlbumListType,
        size: Int,
        offset: Int,
        fromYear: Int?,
        toYear: Int?,
        genre: String?
    ) async throws -> [Album] {
        var query = [
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

        let response = try await send("getAlbumList2.view", query)
        return SubsonicJSON.list(SubsonicJSON.object(response["albumList2"])["album"]) {
            SubsonicJSON.album($0)
        }
    }

    public func album(id: String) async throws -> AlbumDetail {
        let response = try await send("getAlbum.view", [URLQueryItem(name: "id", value: id)])
        let payload = SubsonicJSON.object(response["album"])
        guard let album = SubsonicJSON.album(payload) else {
            throw SubsonicAPIError.invalidResponse("Missing album")
        }
        let songs = SubsonicJSON.list(payload["song"]) { SubsonicJSON.song($0) }
        return AlbumDetail(album: album, songs: songs)
    }

    public func albumInfo(id: String) async throws -> AlbumInfo {
        let response = try await send("getAlbumInfo2.view", [URLQueryItem(name: "id", value: id)])
        return SubsonicJSON.albumInfo(SubsonicJSON.object(response["albumInfo"]))
    }

    public func artists() async throws -> [Artist] {
        let response = try await send("getArtists.view")
        // A library under a single index letter can arrive as one object.
        let indexes = SubsonicJSON.list(SubsonicJSON.object(response["artists"])["index"]) { $0 }
        return indexes.flatMap { index in
            SubsonicJSON.list(index["artist"]) { SubsonicJSON.artist($0) }
        }
    }

    public func artist(id: String) async throws -> ArtistDetail {
        let response = try await send("getArtist.view", [URLQueryItem(name: "id", value: id)])
        let payload = SubsonicJSON.object(response["artist"])
        guard let artist = SubsonicJSON.artist(payload) else {
            throw SubsonicAPIError.invalidResponse("Missing artist")
        }
        let albums = SubsonicJSON.list(payload["album"]) { SubsonicJSON.album($0) }
        return ArtistDetail(artist: artist, albums: albums)
    }

    public func artistInfo(id: String) async throws -> ArtistInfo {
        let response = try await send("getArtistInfo.view", [URLQueryItem(name: "id", value: id)])
        let payload = response["artistInfo"] ?? response["artistInfo2"]
        return SubsonicJSON.artistInfo(SubsonicJSON.object(payload))
    }

    public func topSongs(artistName: String, count: Int) async throws -> [Song] {
        let response = try await send("getTopSongs.view", [
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "count", value: String(count))
        ])
        return SubsonicJSON.list(SubsonicJSON.object(response["topSongs"])["song"]) {
            SubsonicJSON.song($0)
        }
    }

    public func song(id: String) async throws -> Song {
        let response = try await send("getSong.view", [URLQueryItem(name: "id", value: id)])
        guard let song = SubsonicJSON.song(response["song"] as? [String: Any]) else {
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
        var query = [URLQueryItem(name: "size", value: String(size))]
        if let genre {
            query.append(URLQueryItem(name: "genre", value: genre))
        }
        if let fromYear {
            query.append(URLQueryItem(name: "fromYear", value: String(fromYear)))
        }
        if let toYear {
            query.append(URLQueryItem(name: "toYear", value: String(toYear)))
        }

        let response = try await send("getRandomSongs.view", query)
        return SubsonicJSON.list(SubsonicJSON.object(response["randomSongs"])["song"]) {
            SubsonicJSON.song($0)
        }
    }

    public func songsByGenre(_ genre: String, count: Int, offset: Int) async throws -> [Song] {
        let response = try await send("getSongsByGenre.view", [
            URLQueryItem(name: "genre", value: genre),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "offset", value: String(offset))
        ])
        return SubsonicJSON.list(SubsonicJSON.object(response["songsByGenre"])["song"]) {
            SubsonicJSON.song($0)
        }
    }

    public func genres() async throws -> [Genre] {
        let response = try await send("getGenres.view")
        return SubsonicJSON.list(SubsonicJSON.object(response["genres"])["genre"]) { dict in
            guard let name = SubsonicJSON.string(dict["value"]) else { return nil }
            return Genre(
                name: name,
                songCount: SubsonicJSON.int(dict["songCount"]) ?? 0,
                albumCount: SubsonicJSON.int(dict["albumCount"]) ?? 0
            )
        }
    }

    public func starred() async throws -> SearchResults {
        let response = try await send("getStarred2.view")
        return SubsonicJSON.searchResults(SubsonicJSON.object(response["starred2"]))
    }

    public func search(_ query: String, page: SearchPage) async throws -> SearchResults {
        let response = try await send("search3.view", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: String(page.artistCount)),
            URLQueryItem(name: "artistOffset", value: String(page.artistOffset)),
            URLQueryItem(name: "albumCount", value: String(page.albumCount)),
            URLQueryItem(name: "albumOffset", value: String(page.albumOffset)),
            URLQueryItem(name: "songCount", value: String(page.songCount)),
            URLQueryItem(name: "songOffset", value: String(page.songOffset))
        ])
        return SubsonicJSON.searchResults(SubsonicJSON.object(response["searchResult3"]))
    }

    // MARK: Playlists

    public func playlists() async throws -> [Playlist] {
        let response = try await send("getPlaylists.view")
        return SubsonicJSON.list(SubsonicJSON.object(response["playlists"])["playlist"]) {
            SubsonicJSON.playlist($0)
        }
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        let response = try await send("getPlaylist.view", [URLQueryItem(name: "id", value: id)])
        guard let detail = SubsonicJSON.playlistDetail(response["playlist"] as? [String: Any]) else {
            throw SubsonicAPIError.invalidResponse("Missing playlist")
        }
        return detail
    }

    public func createPlaylist(name: String, songIds: [String]) async throws -> PlaylistDetail? {
        let query = [URLQueryItem(name: "name", value: name)]
            + songIds.map { URLQueryItem(name: "songId", value: $0) }
        let response = try await send("createPlaylist.view", query)
        return SubsonicJSON.playlistDetail(response["playlist"] as? [String: Any])
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
        query += changes.songIdsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) }
        query += changes.songIndexesToRemove.map {
            URLQueryItem(name: "songIndexToRemove", value: String($0))
        }

        try await send("updatePlaylist.view", query)
    }

    public func deletePlaylist(id: String) async throws {
        try await send("deletePlaylist.view", [URLQueryItem(name: "id", value: id)])
    }

    // MARK: Annotation

    public func star(_ target: StarTarget) async throws {
        try await annotate("star.view", target)
    }

    public func unstar(_ target: StarTarget) async throws {
        try await annotate("unstar.view", target)
    }

    private func annotate(_ path: String, _ target: StarTarget) async throws {
        let query = target.songIds.map { URLQueryItem(name: "id", value: $0) }
            + target.albumIds.map { URLQueryItem(name: "albumId", value: $0) }
            + target.artistIds.map { URLQueryItem(name: "artistId", value: $0) }
        guard !query.isEmpty else { return }
        try await send(path, query)
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

        try await send("scrobble.view", query)
    }

    // MARK: Internet radio

    public func radioStations() async throws -> [RadioStation] {
        let response = try await send("getInternetRadioStations.view")
        let payload = SubsonicJSON.object(response["internetRadioStations"])
        return SubsonicJSON.list(payload["internetRadioStation"]) {
            SubsonicJSON.radioStation($0)
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

        // POST, like the web client.
        try await send("createInternetRadioStation.view", query, method: .post)
    }

    public func updateRadioStation(_ station: RadioStation) async throws {
        try await send("updateInternetRadioStation.view", [
            URLQueryItem(name: "id", value: station.id),
            URLQueryItem(name: "streamUrl", value: station.streamUrl),
            URLQueryItem(name: "name", value: station.name),
            URLQueryItem(name: "homepageUrl", value: station.homePageUrl ?? "")
        ])
    }

    public func deleteRadioStation(id: String) async throws {
        try await send(
            "deleteInternetRadioStation.view",
            [URLQueryItem(name: "id", value: id)]
        )
    }

    // MARK: Lyrics

    public func lyrics(artist: String, title: String) async throws -> SubsonicPlainLyrics? {
        let response = try await send("getLyrics.view", [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title)
        ])
        let payload = SubsonicJSON.object(response["lyrics"])
        guard let value = SubsonicJSON.string(payload["value"]),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return SubsonicPlainLyrics(
            artist: SubsonicJSON.string(payload["artist"]),
            title: SubsonicJSON.string(payload["title"]),
            value: value
        )
    }

    public func lyricsBySongId(_ id: String) async throws -> [SubsonicStructuredLyrics] {
        let response = try await send(
            "getLyricsBySongId.view",
            [URLQueryItem(name: "id", value: id)]
        )
        let payload = SubsonicJSON.object(response["lyricsList"])
        return SubsonicJSON.list(payload["structuredLyrics"]) {
            SubsonicJSON.structuredLyrics($0)
        }
    }
}

/// Signs requests with the stored credentials through
/// `AuthenticationService.url(path:query:)` and appends repeated parameters.
public struct AuthenticatedSubsonicTransport: SubsonicTransport {
    private let client: HTTPClient
    private let urlBuilder: @Sendable (String) -> URL?

    public init(
        authentication: AuthenticationService = .shared,
        client: HTTPClient = NetworkService.shared.client()
    ) {
        self.init(urlBuilder: { authentication.url(path: $0) }, client: client)
    }

    public init(authentication: AuthenticationService = .shared, session: URLSession) {
        self.init(authentication: authentication, client: HTTPClient(session: session))
    }

    internal init(
        urlBuilder: @escaping @Sendable (String) -> URL?,
        session: URLSession
    ) {
        self.init(urlBuilder: urlBuilder, client: HTTPClient(session: session))
    }

    internal init(
        urlBuilder: @escaping @Sendable (String) -> URL?,
        client: HTTPClient
    ) {
        self.client = client
        self.urlBuilder = urlBuilder
    }

    public func send(_ request: SubsonicRequest) async throws -> Data {
        guard let signedURL = urlBuilder(request.path) else {
            throw SubsonicAPIError.notSignedIn
        }
        guard var components = URLComponents(url: signedURL, resolvingAgainstBaseURL: false) else {
            throw SubsonicAPIError.invalidResponse("Invalid server URL")
        }

        // Encoded by hand: `queryItems` leaves `+` as is, which servers
        // read as a space.
        let items = request.query.compactMap { item in
            item.value.map { URLQueryItem(name: item.name, value: Self.percentEncode($0)) }
        }
        components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + items
        guard let url = components.url else {
            throw SubsonicAPIError.invalidResponse("Invalid request URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30

        let result: (Data, URLResponse)
        do {
            result = try await client.data(for: urlRequest)
        } catch {
            throw SubsonicAPIError(mapping: error)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw SubsonicAPIError.offline
        }
        guard (200...299).contains(response.statusCode) else {
            throw SubsonicAPIError.http(status: response.statusCode)
        }
        return result.0
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+=&")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
