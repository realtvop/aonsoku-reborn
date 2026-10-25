import Foundation

/// Options for a library sync started by the app.
public struct LibrarySyncOptions: Hashable, Sendable {
    /// Cover art downloaded after the metadata tiers (web sync `coverArt`
    /// phase).
    public struct CoverArt: Hashable, Sendable {
        /// Parallel downloads, 1...8.
        public var concurrency: Int
        /// Songs use their album's cover, so song covers are skipped and
        /// every album id is cached too.
        public var useAlbumCoverForSongs: Bool
        /// Requested pixel size.
        public var size: String

        public init(concurrency: Int = 4, useAlbumCoverForSongs: Bool = false, size: String = "700") {
            self.concurrency = concurrency
            self.useAlbumCoverForSongs = useAlbumCoverForSongs
            self.size = size
        }
    }

    /// Fetches every song, not only starred and recent ones.
    public var includeFullSongs: Bool
    /// nil skips the cover art phase.
    public var coverArt: CoverArt?

    public init(includeFullSongs: Bool = true, coverArt: CoverArt? = nil) {
        self.includeFullSongs = includeFullSongs
        self.coverArt = coverArt
    }
}

extension LibraryService {
    /// Syncs every tier regardless of freshness, then cover art when
    /// requested. Progress arrives as `syncStateChanged` events; the cover
    /// art phase reports `phase == "coverArt"`.
    public func syncAll(options: LibrarySyncOptions) {
        syncAll(with: options)
    }

    /// Syncs tiers that are no longer fresh, then cover art when requested.
    public func syncIncremental(options: LibrarySyncOptions) {
        syncIncremental(with: options)
    }
}
