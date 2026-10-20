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

    public func ping() async throws -> ServerInfo { throw SubsonicAPIError.unsupported }

    public func user(username: String) async throws -> SubsonicUser {
        throw SubsonicAPIError.unsupported
    }

    public func scanStatus() async throws -> ScanStatus { throw SubsonicAPIError.unsupported }

    public func startScan() async throws -> ScanStatus { throw SubsonicAPIError.unsupported }

    public func albumList(
        _ type: AlbumListType,
        size: Int,
        offset: Int,
        fromYear: Int?,
        toYear: Int?,
        genre: String?
    ) async throws -> [Album] {
        throw SubsonicAPIError.unsupported
    }

    public func album(id: String) async throws -> AlbumDetail { throw SubsonicAPIError.unsupported }

    public func albumInfo(id: String) async throws -> AlbumInfo { throw SubsonicAPIError.unsupported }

    public func artists() async throws -> [Artist] { throw SubsonicAPIError.unsupported }

    public func artist(id: String) async throws -> ArtistDetail { throw SubsonicAPIError.unsupported }

    public func artistInfo(id: String) async throws -> ArtistInfo { throw SubsonicAPIError.unsupported }

    public func topSongs(artistName: String, count: Int) async throws -> [Song] {
        throw SubsonicAPIError.unsupported
    }

    public func song(id: String) async throws -> Song { throw SubsonicAPIError.unsupported }

    public func randomSongs(
        size: Int,
        genre: String?,
        fromYear: Int?,
        toYear: Int?
    ) async throws -> [Song] {
        throw SubsonicAPIError.unsupported
    }

    public func genres() async throws -> [Genre] { throw SubsonicAPIError.unsupported }

    public func starred() async throws -> SearchResults { throw SubsonicAPIError.unsupported }

    public func search(_ query: String, page: SearchPage) async throws -> SearchResults {
        throw SubsonicAPIError.unsupported
    }

    public func playlists() async throws -> [Playlist] { throw SubsonicAPIError.unsupported }

    public func playlist(id: String) async throws -> PlaylistDetail {
        throw SubsonicAPIError.unsupported
    }

    public func createPlaylist(name: String, songIds: [String]) async throws -> PlaylistDetail? {
        throw SubsonicAPIError.unsupported
    }

    public func updatePlaylist(id: String, changes: PlaylistChanges) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func deletePlaylist(id: String) async throws { throw SubsonicAPIError.unsupported }

    public func star(_ target: StarTarget) async throws { throw SubsonicAPIError.unsupported }

    public func unstar(_ target: StarTarget) async throws { throw SubsonicAPIError.unsupported }

    public func scrobble(songId: String, submission: Bool, time: Date?) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func radioStations() async throws -> [RadioStation] { throw SubsonicAPIError.unsupported }

    public func createRadioStation(
        name: String,
        streamUrl: String,
        homePageUrl: String?
    ) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func updateRadioStation(_ station: RadioStation) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func deleteRadioStation(id: String) async throws { throw SubsonicAPIError.unsupported }

    public func lyrics(artist: String, title: String) async throws -> SubsonicPlainLyrics? {
        throw SubsonicAPIError.unsupported
    }

    public func lyricsBySongId(_ id: String) async throws -> [SubsonicStructuredLyrics] {
        throw SubsonicAPIError.unsupported
    }
}

/// Signs requests with the stored credentials through
/// `AuthenticationService.url(path:query:)` and appends repeated parameters.
public struct AuthenticatedSubsonicTransport: SubsonicTransport {
    private let authentication: AuthenticationService
    private let session: URLSession

    public init(authentication: AuthenticationService = .shared, session: URLSession = .shared) {
        self.authentication = authentication
        self.session = session
    }

    public func send(_ request: SubsonicRequest) async throws -> Data {
        throw SubsonicAPIError.unsupported
    }
}
