import Foundation

public struct LibraryPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let total: Int
    public let hasMore: Bool

    public init(items: [Item], total: Int, hasMore: Bool) {
        self.items = items
        self.total = total
        self.hasMore = hasMore
    }
}

public struct LibraryArtistFilter: Sendable {
    public var search: String?
    public var starredOnly: Bool?
    public var sortBy: String?
    public var sortOrder: String?

    public init(
        search: String? = nil,
        starredOnly: Bool? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil
    ) {
        self.search = search
        self.starredOnly = starredOnly
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

public struct LibraryAlbumFilter: Sendable {
    public var search: String?
    public var artistId: String?
    public var genre: String?
    public var fromYear: Int?
    public var toYear: Int?
    public var starredOnly: Bool?
    public var sortBy: String?
    public var sortOrder: String?

    public init(
        search: String? = nil,
        artistId: String? = nil,
        genre: String? = nil,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        starredOnly: Bool? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil
    ) {
        self.search = search
        self.artistId = artistId
        self.genre = genre
        self.fromYear = fromYear
        self.toYear = toYear
        self.starredOnly = starredOnly
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

public struct LibrarySongFilter: Sendable {
    public var search: String?
    public var albumId: String?
    public var artistId: String?
    public var genre: String?
    public var starredOnly: Bool?
    public var sortBy: String?
    public var sortOrder: String?

    public init(
        search: String? = nil,
        albumId: String? = nil,
        artistId: String? = nil,
        genre: String? = nil,
        starredOnly: Bool? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil
    ) {
        self.search = search
        self.albumId = albumId
        self.artistId = artistId
        self.genre = genre
        self.starredOnly = starredOnly
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }
}

public struct LibraryArtist: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let albumCount: Int
    public let coverArt: String?
    public let artistImageUrl: String?
    public let starred: String?
    public let starredAt: Int?
    public let musicBrainzId: String?
    public let sortName: String?
}

public struct LibraryAlbum: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let artist: String
    public let artistId: String?
    public let coverArt: String?
    public let songCount: Int
    public let duration: Int
    public let year: Int?
    public let genre: String?
    public let created: String?
    public let played: String?
    public let playCount: Int?
    public let starred: String?
    public let starredAt: Int?
}

public struct LibrarySong: Codable, Equatable, Sendable {
    public let id: String
    public let parent: String?
    public let title: String
    public let album: String?
    public let artist: String?
    public let track: Int?
    public let year: Int?
    public let genre: String?
    public let coverArt: String?
    public let size: Int?
    public let contentType: String?
    public let suffix: String?
    public let duration: Int
    public let bitRate: Int?
    public let path: String?
    public let playCount: Int?
    public let discNumber: Int?
    public let created: String?
    public let albumId: String?
    public let artistId: String?
    public let played: String?
    public let starred: String?
    public let starredAt: Int?
    public let playedAt: Int?
    public let bpm: Int?
    public let comment: String?
    public let sortName: String?
    public let mediaType: String?
    public let musicBrainzId: String?
    public let genresJSON: String?
    public let replayGainJSON: String?
}

public struct LibraryAlbumDetail: Equatable, Sendable {
    public let album: LibraryAlbum
    public let songs: [LibrarySong]
}

public struct LibraryPlaylist: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let comment: String?
    public let songCount: Int
    public let duration: Int
    public let isPublic: Bool
    public let owner: String?
    public let created: String?
    public let changed: String?
    public let coverArt: String?
    public let starred: String?
    public let starredAt: Int?
}

public struct LibraryPlaylistDetail: Codable, Equatable, Sendable {
    public let playlist: LibraryPlaylist
    public let entriesJSON: String
}

public struct LibraryGenre: Codable, Equatable, Sendable {
    public let value: String
    public let songCount: Int?
    public let albumCount: Int?
}

public struct LibraryLyrics: Codable, Equatable, Sendable {
    public let songId: String
    public let content: String
    public let synced: Bool?
    public let cachedAt: Int
    public let lastAccessedAt: Int
}

public struct LibrarySearchResults: Equatable, Sendable {
    public let artists: [LibraryArtist]
    public let albums: [LibraryAlbum]
    public let songs: [LibrarySong]
}

public struct LibraryCacheStats: Equatable, Sendable {
    public let totalItems: Int
    public let totalSizeBytes: Int
    public let audioCount: Int
    public let coverCount: Int
}

public struct LibraryAvailability: Equatable, Sendable {
    public let available: Bool
    public let lastSyncedAt: Int?
}

public struct LibraryInitialization: Equatable, Sendable {
    public let ready: Bool
    public let needsMigration: Bool
}

public struct LibrarySyncState: Equatable, Sendable {
    public let phase: String
    public let tier: String?
    public let isSyncing: Bool
    public let processedItems: Int
    public let totalItems: Int
}

public enum LibraryEvent: Equatable, Sendable {
    case syncStateChanged(LibrarySyncState)
    case dataChanged(tables: [String])
}

public struct LibraryCachedImage: Equatable, Sendable {
    public let id: String
    public let uri: String
    public let contentType: String?
    public let sizeBytes: Int?
    public let requestedSize: String
}

public struct LibraryCoverSize: Equatable, Sendable {
    public let sizeBytes: Int
    public let coverSize: String?
}
