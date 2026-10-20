import Foundation
import Observation

/// Offline downloads and the cache manager (web `src/service/cache/*`).
///
/// Every cached file has a row in the native `cacheMeta` index with its
/// source: `explicit` downloads are never evicted, `smart` entries follow the
/// smart download rules, and `lru` entries come from streaming and are
/// evicted oldest first over the quota. Albums and playlists get marker
/// rows so they show as downloaded.
@MainActor
@Observable
public final class DownloadsStore {
    public private(set) var usage = CacheUsage()
    public private(set) var activeDownloads = ActiveDownloadsSummary()
    /// Increments when the index changes, for screens listing downloads.
    public private(set) var revision = 0

    @ObservationIgnored public let audio: AudioService
    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public weak var favorites: FavoritesStore?
    @ObservationIgnored public weak var toasts: ToastCenter?

    public init(
        audio: AudioService,
        library: LibraryService,
        repository: LibraryRepository,
        settings: SettingsStore
    ) {
        self.audio = audio
        self.library = library
        self.repository = repository
        self.settings = settings
    }

    /// Subscribes to download and stream-cache events and loads the index.
    public func start() {}

    // MARK: State

    public func state(ofSong id: String) -> SongCacheState { .notCached }
    public func state(ofAlbum id: String) -> CollectionCacheState { .notCached }
    public func state(ofPlaylist id: String) -> CollectionCacheState { .notCached }

    // MARK: Downloads

    public func download(songs: [Song]) async {}
    public func download(albumId: String) async {}
    public func download(playlistId: String) async {}
    public func download(artistId: String) async {}

    /// Removes explicit downloads; songs kept by another source stay.
    public func remove(songIds: [String]) async {}
    public func remove(albumId: String) async {}
    public func remove(playlistId: String) async {}

    public func cancelAll() {}

    // MARK: Offline library

    public func downloadedAlbums() async -> [Album] { [] }
    public func downloadedPlaylists() async -> [Playlist] { [] }
    public func downloadedSongs() async -> [Song] { [] }

    // MARK: Cache manager

    public func items(filter: CacheFilter) async -> [CachedItem] { [] }
    public func delete(_ items: [CachedItem]) async {}
    /// Deletes audio and collection markers of one source.
    public func clear(source: CacheSource) async {}
    /// Deletes all cover art.
    public func clearAssets() async {}
    public func refreshUsage() async {}

    /// Applies the smart rules: downloads favorite songs and songs of
    /// favorite playlists, and removes smart entries that no longer match.
    /// Skipped on metered networks.
    public func applySmartRules() async {}

    /// Deletes least recently used entries over the quotas.
    public func enforceQuotas() async {}
}
