import Foundation

/// Album sections on Home, in display order after the carousel and pins.
public enum HomeSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case recentlyPlayed
    case mostPlayed
    case recentlyAdded
    case explore

    public var id: String { rawValue }

    public var titleKey: String { "home.\(rawValue)" }

    /// The full list that "See All" opens.
    public var listFilter: AlbumListFilter {
        switch self {
        case .recentlyPlayed: .recentlyPlayed
        case .mostPlayed: .mostPlayed
        case .recentlyAdded: .recentlyAdded
        case .explore: .random
        }
    }

    /// Albums per section (web `HOME_SECTION_SIZE`).
    public static let size = 16
    /// Albums in the Home carousel.
    public static let carouselSize = 10
}

/// Library reads for the native UI.
///
/// Lists read the synced local library (`LibraryService`), so they work
/// offline and page instantly. Before the first sync has finished they fall
/// back to the server. Details are read from the server when online, for
/// fields the local library does not keep, and fall back to the local copy
/// when offline or on a connectivity failure. `cached*` variants return the
/// local copy immediately so screens can render before the server replies.
///
/// Mirrors the web native list paths (`src/service/*`, `src/native/data/*`,
/// `src/lib/offlineQueryClient.ts`).
public final class LibraryRepository: @unchecked Sendable {
    public let api: any SubsonicAPI
    public let library: LibraryService
    public let connectivity: any Connectivity

    public init(
        api: any SubsonicAPI,
        library: LibraryService = AppServices.shared.library,
        connectivity: any Connectivity
    ) {
        self.api = api
        self.library = library
        self.connectivity = connectivity
    }

    // MARK: - Lists

    /// Albums for a list screen. Sort and direction follow the web
    /// `sortMap`: newest and recent descending, byYear newest first unless
    /// `newestFirst` is false, random shuffled. `.search` matches every word.
    public func albums(
        _ filter: AlbumListFilter,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Album> {
        throw SubsonicAPIError.unsupported
    }

    /// Artists by name. `starredOnly` lists favorite artists.
    public func artists(
        search: String = "",
        starredOnly: Bool = false,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Artist> {
        throw SubsonicAPIError.unsupported
    }

    public func songs(
        _ query: SongListQuery,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Song> {
        throw SubsonicAPIError.unsupported
    }

    /// Genres by name, with song and album counts.
    public func genres() async throws -> [Genre] {
        throw SubsonicAPIError.unsupported
    }

    /// The user's playlists, most recently changed first.
    public func playlists() async throws -> [Playlist] {
        throw SubsonicAPIError.unsupported
    }

    // MARK: - Details

    public func album(id: String) async throws -> AlbumDetail {
        throw SubsonicAPIError.unsupported
    }

    public func cachedAlbum(id: String) async -> AlbumDetail? { nil }

    /// The artist and their albums, newest first (discography).
    public func artist(id: String) async throws -> ArtistDetail {
        throw SubsonicAPIError.unsupported
    }

    public func cachedArtist(id: String) async -> ArtistDetail? { nil }

    public func playlist(id: String) async throws -> PlaylistDetail {
        throw SubsonicAPIError.unsupported
    }

    public func cachedPlaylist(id: String) async -> PlaylistDetail? { nil }

    public func song(id: String) async throws -> Song {
        throw SubsonicAPIError.unsupported
    }

    /// Songs for `ids` in the same order, from the local library first and
    /// the server for misses. Unknown ids are skipped.
    public func songs(ids: [String]) async throws -> [Song] {
        throw SubsonicAPIError.unsupported
    }

    /// Album notes and links; nil offline or when the server has none.
    public func albumInfo(id: String) async -> AlbumInfo? { nil }

    /// Biography, image and similar artists; nil offline or when the server
    /// has none.
    public func artistInfo(id: String) async -> ArtistInfo? { nil }

    /// Most popular songs by the artist; empty offline.
    public func topSongs(artistName: String, count: Int = 10) async -> [Song] { [] }

    // MARK: - Home and search

    /// Albums for a Home section (web `useHomeData`): the server lists when
    /// online, else the local library (newest by created, frequent by summed
    /// play count, recent by last played, random shuffled).
    public func homeAlbums(_ section: HomeSection, size: Int) async throws -> [Album] {
        throw SubsonicAPIError.unsupported
    }

    /// Random albums for the Home carousel.
    public func carouselAlbums(size: Int = HomeSection.carouselSize) async throws -> [Album] {
        throw SubsonicAPIError.unsupported
    }

    /// `search3` when online; otherwise a local search where every word must
    /// match. Returns up to `limit` of each kind.
    public func search(_ text: String, limit: Int = 20) async throws -> SearchResults {
        throw SubsonicAPIError.unsupported
    }

    public func randomSongs(size: Int, genre: String? = nil) async throws -> [Song] {
        throw SubsonicAPIError.unsupported
    }

    // MARK: - Server

    public func scanStatus() async throws -> ScanStatus {
        throw SubsonicAPIError.unsupported
    }

    public func startScan() async throws -> ScanStatus {
        throw SubsonicAPIError.unsupported
    }
}
