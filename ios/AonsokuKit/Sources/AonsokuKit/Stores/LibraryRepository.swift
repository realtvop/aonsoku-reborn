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
    /// The signed-in server type (`navidrome`, `lms`, ...), read from any
    /// thread. Navidrome needs `""` to list everything through `search3`.
    public let serverType: @Sendable () -> String?

    public init(
        api: any SubsonicAPI,
        library: LibraryService = AppServices.shared.library,
        connectivity: any Connectivity,
        serverType: @escaping @Sendable () -> String? = { nil }
    ) {
        self.api = api
        self.library = library
        self.connectivity = connectivity
        self.serverType = serverType
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
        if isLocalReady {
            return try localAlbums(filter, offset: offset, limit: limit)
        }
        return try await serverAlbums(filter, offset: offset, limit: limit)
    }

    /// Artists by name. `starredOnly` lists favorite artists.
    public func artists(
        search: String = "",
        starredOnly: Bool = false,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Artist> {
        if isLocalReady {
            let page = try library.artists(
                limit: limit,
                offset: offset,
                filter: LibraryArtistFilter(
                    search: search,
                    starredOnly: starredOnly,
                    sortBy: starredOnly ? "starredAt" : "name",
                    sortOrder: starredOnly ? "desc" : "asc"
                )
            )
            return page.map(\.mediaValue)
        }

        let all = try await (starredOnly ? api.starred().artists : api.artists())
        let filtered = all
            .filter { search.matchesEveryWord(in: [$0.name]) }
            .sorted { $0.name.localizedAscending($1.name) }
        return filtered.page(offset: offset, limit: limit)
    }

    public func songs(
        _ query: SongListQuery,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Song> {
        if isLocalReady {
            return try localSongs(query, offset: offset, limit: limit)
        }
        return try await serverSongs(query, offset: offset, limit: limit)
    }

    /// Genres by name, with song and album counts.
    public func genres() async throws -> [Genre] {
        let genres = if isLocalReady {
            try library.genres().map(\.mediaValue)
        } else {
            try await api.genres()
        }
        return genres.sorted { $0.name.localizedAscending($1.name) }
    }

    /// The user's playlists, most recently changed first.
    public func playlists() async throws -> [Playlist] {
        let values = if isLocalReady {
            try library.playlists(limit: Int.max).items.map(\.mediaValue)
        } else {
            try await api.playlists()
        }
        return values.sorted(by: Self.playlistOrder)
    }

    // MARK: - Details

    public func album(id: String) async throws -> AlbumDetail {
        try await detail(server: { try await api.album(id: id) }, cached: {
            await cachedAlbum(id: id)
        })
    }

    public func cachedAlbum(id: String) async -> AlbumDetail? {
        try? library.album(id: id).map {
            AlbumDetail(
                album: $0.album.mediaValue,
                songs: $0.songs.map(\.mediaValue)
            )
        }
    }

    /// The artist and their albums, newest first (discography).
    public func artist(id: String) async throws -> ArtistDetail {
        try await detail(server: {
            let result = try await api.artist(id: id)
            return ArtistDetail(
                artist: result.artist,
                albums: result.albums.sorted(by: Self.albumYearOrder)
            )
        }, cached: {
            await cachedArtist(id: id)
        })
    }

    public func cachedArtist(id: String) async -> ArtistDetail? {
        guard let artist = try? library.artist(id: id)?.mediaValue else { return nil }
        let page = try? library.albums(
            limit: Int.max,
            filter: LibraryAlbumFilter(
                artistId: id,
                sortBy: "year",
                sortOrder: "desc"
            )
        )
        return ArtistDetail(
            artist: artist,
            albums: page?.items.map(\.mediaValue).sorted(by: Self.albumYearOrder) ?? []
        )
    }

    public func playlist(id: String) async throws -> PlaylistDetail {
        try await detail(server: { try await api.playlist(id: id) }, cached: {
            await cachedPlaylist(id: id)
        })
    }

    public func cachedPlaylist(id: String) async -> PlaylistDetail? {
        try? library.playlist(id: id)?.mediaValue
    }

    public func song(id: String) async throws -> Song {
        try await detail(server: { try await api.song(id: id) }, cached: {
            try? library.songs(ids: [id]).first?.mediaValue
        })
    }

    /// Songs for `ids` in the same order, from the local library first and
    /// the server for misses. Unknown ids are skipped.
    public func songs(ids: [String]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        let local = (try? library.songs(ids: ids))?.map(\.mediaValue) ?? []
        var byId = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        if connectivity.isOnline {
            for id in ids where byId[id] == nil {
                do {
                    byId[id] = try await api.song(id: id)
                } catch let error as SubsonicAPIError {
                    if case .notFound = error { continue }
                    throw error
                }
            }
        }
        return ids.compactMap { byId[$0] }
    }

    /// Album notes and links; nil offline or when the server has none.
    public func albumInfo(id: String) async -> AlbumInfo? {
        guard connectivity.isOnline else { return nil }
        return try? await api.albumInfo(id: id)
    }

    /// Biography, image and similar artists; nil offline or when the server
    /// has none.
    public func artistInfo(id: String) async -> ArtistInfo? {
        guard connectivity.isOnline else { return nil }
        return try? await api.artistInfo(id: id)
    }

    /// Most popular songs by the artist; empty offline.
    public func topSongs(artistName: String, count: Int = 10) async -> [Song] {
        guard connectivity.isOnline else { return [] }
        return (try? await api.topSongs(artistName: artistName, count: count)) ?? []
    }

    // MARK: - Home and search

    /// Albums for a Home section (web `useHomeData`): the server lists when
    /// online, else the local library (newest by created, frequent by summed
    /// play count, recent by last played, random shuffled).
    public func homeAlbums(_ section: HomeSection, size: Int, fallbackToLocal: Bool = true) async throws -> [Album] {
        if connectivity.isOnline {
            do {
                let type: AlbumListType = switch section {
                case .recentlyPlayed: .recent
                case .mostPlayed: .frequent
                case .recentlyAdded: .newest
                case .explore: .random
                }
                return try await api.albumList(
                    type,
                    size: size,
                    offset: 0,
                    fromYear: nil,
                    toYear: nil,
                    genre: nil
                )
            } catch let error as SubsonicAPIError where error.isConnectivityFailure {
                guard fallbackToLocal else { throw error }
                return try localHomeAlbums(section, size: size)
            }
        }
        guard fallbackToLocal else { throw SubsonicAPIError.offline }
        return try localHomeAlbums(section, size: size)
    }

    /// Random albums for the Home carousel.
    public func carouselAlbums(size: Int = HomeSection.carouselSize, fallbackToLocal: Bool = true) async throws -> [Album] {
        if connectivity.isOnline {
            do {
                return try await api.albumList(
                    .random,
                    size: size,
                    offset: 0,
                    fromYear: nil,
                    toYear: nil,
                    genre: nil
                )
            } catch let error as SubsonicAPIError where error.isConnectivityFailure {
                guard fallbackToLocal else { throw error }
            }
        }
        guard fallbackToLocal else { throw SubsonicAPIError.offline }
        return try localHomeAlbums(.explore, size: size)
    }

    /// `search3` when online; otherwise a local search where every word must
    /// match. Returns up to `limit` of each kind.
    public func search(_ text: String, limit: Int = 20) async throws -> SearchResults {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SearchResults() }
        if connectivity.isOnline {
            return try await api.search(
                query,
                page: SearchPage(
                    artistCount: limit,
                    albumCount: limit,
                    songCount: limit
                )
            )
        }
        let result = try library.search(
            query: query,
            artistCount: limit,
            albumCount: limit,
            songCount: limit
        )
        return SearchResults(
            artists: result.artists.map(\.mediaValue),
            albums: result.albums.map(\.mediaValue),
            songs: result.songs.map(\.mediaValue)
        )
    }

    public func randomSongs(size: Int, genre: String? = nil) async throws -> [Song] {
        if connectivity.isOnline {
            return try await api.randomSongs(
                size: size,
                genre: genre,
                fromYear: nil,
                toYear: nil
            )
        }
        let page = try library.songs(
            limit: Int.max,
            filter: LibrarySongFilter(genre: genre)
        )
        return Array(page.items.map(\.mediaValue).shuffled().prefix(size))
    }

    // MARK: - Server

    public func scanStatus() async throws -> ScanStatus {
        try await api.scanStatus()
    }

    public func startScan() async throws -> ScanStatus {
        try await api.startScan()
    }
}

private extension LibraryRepository {
    var isLocalReady: Bool { library.availability().available }

    func localAlbums(
        _ filter: AlbumListFilter,
        offset: Int,
        limit: Int
    ) throws -> LibraryPage<Album> {
        if case let .search(text) = filter, SearchHelper.tokenize(text).isEmpty {
            return LibraryPage(items: [], total: 0, hasMore: false)
        }
        let localFilter: LibraryAlbumFilter
        switch filter {
        case .alphabeticalByName:
            localFilter = LibraryAlbumFilter(sortBy: "name", sortOrder: "asc")
        case .alphabeticalByArtist:
            localFilter = LibraryAlbumFilter(sortBy: "artist", sortOrder: "asc")
        case .recentlyAdded:
            localFilter = LibraryAlbumFilter(sortBy: "created", sortOrder: "desc")
        case .recentlyPlayed:
            localFilter = LibraryAlbumFilter(sortBy: "played", sortOrder: "desc")
        case .mostPlayed:
            localFilter = LibraryAlbumFilter(sortBy: "playCount", sortOrder: "desc")
        case .random:
            localFilter = LibraryAlbumFilter(sortBy: "random")
        case .favorites:
            localFilter = LibraryAlbumFilter(
                starredOnly: true,
                sortBy: "starredAt",
                sortOrder: "desc"
            )
        case let .byYear(newestFirst):
            localFilter = LibraryAlbumFilter(
                sortBy: "year",
                sortOrder: newestFirst ? "desc" : "asc"
            )
        case let .byGenre(name):
            localFilter = LibraryAlbumFilter(
                genre: name,
                sortBy: "name",
                sortOrder: "asc"
            )
        case let .discography(artistId):
            localFilter = LibraryAlbumFilter(
                artistId: artistId,
                sortBy: "year",
                sortOrder: "desc"
            )
        case let .search(text):
            localFilter = LibraryAlbumFilter(
                search: text,
                sortBy: "name",
                sortOrder: "asc"
            )
        }
        return try library.albums(
            limit: limit,
            offset: offset,
            filter: localFilter
        ).map(\.mediaValue)
    }

    func serverAlbums(
        _ filter: AlbumListFilter,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Album> {
        switch filter {
        case let .discography(artistId):
            let detail = try await api.artist(id: artistId)
            return detail.albums.sorted(by: Self.albumYearOrder).page(
                offset: offset,
                limit: limit
            )
        case let .search(text):
            guard !SearchHelper.tokenize(text).isEmpty else {
                return LibraryPage(items: [], total: 0, hasMore: false)
            }
            let result = try await api.search(text, page: .albums(count: limit, offset: offset))
            return result.albums.serverPage(offset: offset, limit: limit)
        default:
            let request: (AlbumListType, Int?, Int?, String?)
            switch filter {
            case .alphabeticalByName:
                request = (.alphabeticalByName, nil, nil, nil)
            case .alphabeticalByArtist:
                request = (.alphabeticalByArtist, nil, nil, nil)
            case .recentlyAdded:
                request = (.newest, nil, nil, nil)
            case .recentlyPlayed:
                request = (.recent, nil, nil, nil)
            case .mostPlayed:
                request = (.frequent, nil, nil, nil)
            case .random:
                request = (.random, nil, nil, nil)
            case .favorites:
                request = (.starred, nil, nil, nil)
            case let .byYear(newestFirst):
                request = newestFirst
                    ? (.byYear, Calendar.current.component(.year, from: Date()), 0, nil)
                    : (.byYear, 0, Calendar.current.component(.year, from: Date()), nil)
            case let .byGenre(name):
                request = (.byGenre, nil, nil, name)
            case .discography, .search:
                throw SubsonicAPIError.unsupported
            }
            let items = try await api.albumList(
                request.0,
                size: limit,
                offset: offset,
                fromYear: request.1,
                toYear: request.2,
                genre: request.3
            )
            return items.serverPage(offset: offset, limit: limit)
        }
    }

    func localSongs(
        _ query: SongListQuery,
        offset: Int,
        limit: Int
    ) throws -> LibraryPage<Song> {
        if case let .album(id) = query.scope {
            let songs = try library.album(id: id)?.songs.map(\.mediaValue) ?? []
            let filtered = songs.filter { query.search.matchesEveryWord(
                in: [$0.title, $0.artist, $0.album]
            ) }
            return filtered.page(offset: offset, limit: limit)
        }

        if case let .artist(id, _) = query.scope {
            let albumIds = Set(try library.albums(
                limit: Int.max,
                filter: LibraryAlbumFilter(artistId: id)
            ).items.map(\.id))
            let songs = try library.songs(limit: Int.max).items
                .map(\.mediaValue)
                .filter { $0.artistId == id || $0.albumId.map(albumIds.contains) == true }
                .filter { query.search.matchesEveryWord(in: [$0.title, $0.artist, $0.album]) }
                .sorted { Self.songOrder($0, $1, query: query) }
            return songs.page(offset: offset, limit: limit)
        }

        var filter = LibrarySongFilter(
            search: query.search,
            sortBy: query.sort.localSort,
            sortOrder: query.ascending ? "asc" : "desc"
        )
        switch query.scope {
        case .all: break
        case .favorites: filter.starredOnly = true
        case let .genre(name): filter.genre = name
        case .artist, .album: break
        }
        return try library.songs(
            limit: limit,
            offset: offset,
            filter: filter
        ).map(\.mediaValue)
    }

    func serverSongs(
        _ query: SongListQuery,
        offset: Int,
        limit: Int
    ) async throws -> LibraryPage<Song> {
        let values: [Song]
        let isKnownTotal: Bool
        switch query.scope {
        case .all:
            let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = search.isEmpty ? buildAllSongsQuery(serverType: serverType() ?? "") : search
            values = try await api.search(text, page: .songs(count: limit, offset: offset)).songs
            isKnownTotal = false
        case .favorites:
            values = try await api.starred().songs
            isKnownTotal = true
        case let .artist(id, _):
            let artist = try await api.artist(id: id)
            var songs: [Song] = []
            for album in artist.albums {
                songs += try await api.album(id: album.id).songs
            }
            values = songs
            isKnownTotal = true
        case let .album(id):
            let songs = try await api.album(id: id).songs
                .filter { query.search.matchesEveryWord(in: [$0.title, $0.artist, $0.album]) }
            return songs.page(offset: offset, limit: limit)
        case let .genre(name):
            values = try await api.songsByGenre(name, count: limit, offset: offset)
            isKnownTotal = false
        }

        let sorted = values
            .filter { query.search.matchesEveryWord(in: [$0.title, $0.artist, $0.album]) }
            .sorted { Self.songOrder($0, $1, query: query) }
        return isKnownTotal
            ? sorted.page(offset: offset, limit: limit)
            : sorted.serverPage(offset: offset, limit: limit)
    }

    func detail<T: Sendable>(
        server: () async throws -> T,
        cached: () async -> T?
    ) async throws -> T {
        if !connectivity.isOnline {
            if let value = await cached() { return value }
            throw SubsonicAPIError.offline
        }
        do {
            return try await server()
        } catch let error as SubsonicAPIError {
            if error.isConnectivityFailure, let value = await cached() { return value }
            throw error
        }
    }

    func localHomeAlbums(_ section: HomeSection, size: Int) throws -> [Album] {
        var albums = try library.albums(limit: Int.max).items.map(\.mediaValue)
        if section == .explore { return Array(albums.shuffled().prefix(size)) }

        let songs = try library.songs(limit: Int.max).items.map(\.mediaValue)
        var playCounts: [String: Int] = [:]
        var playedDates: [String: Date] = [:]
        for song in songs {
            guard let albumId = song.albumId else { continue }
            playCounts[albumId, default: 0] += song.playCount ?? 0
            if let played = song.played,
               played > (playedDates[albumId] ?? .distantPast) {
                playedDates[albumId] = played
            }
        }

        switch section {
        case .recentlyPlayed:
            albums = albums
                .filter { max($0.played ?? .distantPast, playedDates[$0.id] ?? .distantPast) > .distantPast }
                .sorted {
                    max($0.played ?? .distantPast, playedDates[$0.id] ?? .distantPast)
                        > max($1.played ?? .distantPast, playedDates[$1.id] ?? .distantPast)
                }
        case .mostPlayed:
            albums = albums
                .filter { (playCounts[$0.id] ?? $0.playCount ?? 0) > 0 }
                .sorted {
                    (playCounts[$0.id] ?? $0.playCount ?? 0)
                        > (playCounts[$1.id] ?? $1.playCount ?? 0)
                }
        case .recentlyAdded:
            albums.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .explore: break
        }
        return Array(albums.prefix(size))
    }

    static func songOrder(_ lhs: Song, _ rhs: Song, query: SongListQuery) -> Bool {
        let comparison: ComparisonResult = switch query.sort {
        case .recentlyAdded:
            (lhs.created ?? .distantPast).compare(rhs.created ?? .distantPast)
        case .title: lhs.title.localizedComparison(rhs.title)
        case .artist: lhs.artist.localizedComparison(rhs.artist)
        case .album: lhs.album.localizedComparison(rhs.album)
        }
        return query.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    static func albumYearOrder(_ lhs: Album, _ rhs: Album) -> Bool {
        if (lhs.year ?? 0) != (rhs.year ?? 0) { return (lhs.year ?? 0) > (rhs.year ?? 0) }
        return lhs.name.localizedAscending(rhs.name)
    }

    static func playlistOrder(_ lhs: Playlist, _ rhs: Playlist) -> Bool {
        if (lhs.changed ?? .distantPast) != (rhs.changed ?? .distantPast) {
            return (lhs.changed ?? .distantPast) > (rhs.changed ?? .distantPast)
        }
        return lhs.name.localizedAscending(rhs.name)
    }
}

private extension SongSort {
    var localSort: String {
        switch self {
        case .recentlyAdded: "created"
        case .title: "title"
        case .artist: "artist"
        case .album: "album"
        }
    }
}

private extension LibraryPage {
    func map<Output: Sendable>(_ transform: (Item) -> Output) -> LibraryPage<Output> {
        LibraryPage<Output>(items: items.map(transform), total: total, hasMore: hasMore)
    }
}

private extension Array where Element: Sendable {
    func page(offset: Int, limit: Int) -> LibraryPage<Element> {
        let start = Swift.min(Swift.max(0, offset), count)
        let end = Swift.min(start + Swift.max(0, limit), count)
        return LibraryPage(
            items: Array(self[start..<end]),
            total: count,
            hasMore: end < count
        )
    }

    func serverPage(offset: Int, limit: Int) -> LibraryPage<Element> {
        LibraryPage(
            items: self,
            total: offset + count,
            hasMore: count == limit
        )
    }
}

private extension String {
    func matchesEveryWord(in values: [String]) -> Bool {
        let words = SearchHelper.tokenize(self)
        guard !words.isEmpty else { return true }
        let normalized = values.map {
            $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: nil
            )
        }
        return words.allSatisfy { word in normalized.contains { $0.contains(word) } }
    }

    func localizedComparison(_ other: String) -> ComparisonResult {
        compare(
            other,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: .current
        )
    }

    func localizedAscending(_ other: String) -> Bool {
        localizedComparison(other) == .orderedAscending
    }
}
