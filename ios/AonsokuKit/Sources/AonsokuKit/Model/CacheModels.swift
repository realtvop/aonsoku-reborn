import Foundation

// Offline cache value types. They mirror the web cache index
// (`src/types/cache.ts`, `src/service/cache/cache-manager.ts`): three audio
// pools by source, a cover pool, and album/playlist collection markers.

/// Why an item is cached. Raw values match the stored `source` column.
public enum CacheSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// Downloaded by the user. Never evicted automatically.
    case explicit
    /// Kept by a smart download rule while the rule matches.
    case smart
    /// Cached during playback. Evicted oldest first over the quota.
    case lru

    /// Unknown stored values count as explicit, so they are never evicted.
    public init(stored: String) {
        self = CacheSource(rawValue: stored) ?? .explicit
    }

    public var labelKey: String { "settings.storage.limits.pool.\(rawValue).label" }
    public var descriptionKey: String {
        "settings.storage.limits.pool.\(rawValue).description"
    }
}

/// Kind of cache index entry. Raw values match the stored `type` column.
public enum CachedItemType: String, Codable, Hashable, Sendable, CaseIterable {
    case audio
    case cover
    /// Marker for a downloaded album; carries no bytes itself.
    case album
    /// Marker for a downloaded playlist; carries no bytes itself.
    case playlist

    public var labelKey: String { "settings.storage.cacheManager.list.type_\(rawValue)" }
}

/// One cache index entry with a display name resolved from the library.
public struct CachedItem: Identifiable, Hashable, Sendable {
    /// Index key, such as `audio:<songId>` or `album:<albumId>`.
    public var key: String
    /// Song, album, playlist or cover art id.
    public var itemId: String
    public var type: CachedItemType
    public var source: CacheSource
    public var name: String
    public var subtitle: String?
    public var sizeBytes: Int64
    public var cachedAt: Date
    public var lastAccessedAt: Date
    /// Requested pixel size for cover entries.
    public var coverSize: String?
    /// The server no longer lists this downloaded item.
    public var removedFromServer: Bool

    public var id: String { key }

    public init(
        key: String,
        itemId: String,
        type: CachedItemType,
        source: CacheSource,
        name: String,
        subtitle: String? = nil,
        sizeBytes: Int64,
        cachedAt: Date,
        lastAccessedAt: Date,
        coverSize: String? = nil,
        removedFromServer: Bool = false
    ) {
        self.key = key
        self.itemId = itemId
        self.type = type
        self.source = source
        self.name = name
        self.subtitle = subtitle
        self.sizeBytes = sizeBytes
        self.cachedAt = cachedAt
        self.lastAccessedAt = lastAccessedAt
        self.coverSize = coverSize
        self.removedFromServer = removedFromServer
    }
}

/// Size and entry count of one cache pool.
public struct CachePoolUsage: Hashable, Sendable {
    public var sizeBytes: Int64
    public var count: Int

    public init(sizeBytes: Int64 = 0, count: Int = 0) {
        self.sizeBytes = sizeBytes
        self.count = count
    }
}

/// Usage of every pool shown in Storage settings.
public struct CacheUsage: Hashable, Sendable {
    /// Audio by source. Collection markers are not counted.
    public var explicit = CachePoolUsage()
    public var smart = CachePoolUsage()
    public var lru = CachePoolUsage()
    /// Cover art.
    public var assets = CachePoolUsage()

    public init(
        explicit: CachePoolUsage = CachePoolUsage(),
        smart: CachePoolUsage = CachePoolUsage(),
        lru: CachePoolUsage = CachePoolUsage(),
        assets: CachePoolUsage = CachePoolUsage()
    ) {
        self.explicit = explicit
        self.smart = smart
        self.lru = lru
        self.assets = assets
    }

    public subscript(source: CacheSource) -> CachePoolUsage {
        switch source {
        case .explicit: explicit
        case .smart: smart
        case .lru: lru
        }
    }

    public var totalBytes: Int64 {
        explicit.sizeBytes + smart.sizeBytes + lru.sizeBytes + assets.sizeBytes
    }
}

/// Offline availability of one song, as shown by its row badge.
public enum SongCacheState: Hashable, Sendable {
    case notCached
    /// Fraction 0...1, or nil while the size is unknown.
    case downloading(progress: Double?)
    case cached(source: CacheSource, removedFromServer: Bool)

    public var isCached: Bool {
        if case .cached = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Download state of an album or playlist.
public enum CollectionCacheState: Hashable, Sendable {
    case notCached
    /// Some songs are still downloading.
    case downloading(completed: Int, total: Int)
    /// The collection marker exists and every song is cached.
    case cached

    public var isCached: Bool { self == .cached }
}

/// Summary of in-flight downloads for the downloads banner.
public struct ActiveDownloadsSummary: Hashable, Sendable {
    public var activeCount: Int
    /// Song ids in download order.
    public var songIds: [String]
    /// Fraction 0...1 across songs with a known size.
    public var overallProgress: Double?

    public init(activeCount: Int = 0, songIds: [String] = [], overallProgress: Double? = nil) {
        self.activeCount = activeCount
        self.songIds = songIds
        self.overallProgress = overallProgress
    }

    public var isEmpty: Bool { activeCount == 0 }
}

/// Cache manager list filter. Raw values match the translation keys under
/// `settings.storage.cacheManager.filter`.
public enum CacheFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
    case all
    case audio
    case cover
    case album
    case playlist
    case explicit
    case smart
    case lru

    public var id: String { rawValue }

    public var labelKey: String { "settings.storage.cacheManager.filter.\(rawValue)" }

    public func matches(_ item: CachedItem) -> Bool {
        switch self {
        case .all: true
        case .audio: item.type == .audio
        case .cover: item.type == .cover
        case .album: item.type == .album
        case .playlist: item.type == .playlist
        case .explicit: item.source == .explicit
        case .smart: item.source == .smart
        case .lru: item.source == .lru
        }
    }
}
