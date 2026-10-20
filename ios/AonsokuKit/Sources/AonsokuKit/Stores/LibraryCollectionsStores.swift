import Foundation
import Observation

// MARK: - Pinned

/// An album or playlist pinned to Home (web `pinned_home_store`).
public struct PinnedItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case album
        case playlist
    }

    public var itemId: String
    public var kind: Kind

    public init(itemId: String, kind: Kind) {
        self.itemId = itemId
        self.kind = kind
    }

    /// Unique across kinds.
    public var id: String { "\(kind.rawValue):\(itemId)" }

    private enum CodingKeys: String, CodingKey {
        case itemId = "id"
        case kind = "type"
    }
}

/// A pinned item resolved for display.
public enum PinnedContent: Identifiable, Hashable, Sendable {
    case album(Album)
    case playlist(Playlist)

    public var id: String {
        switch self {
        case let .album(album): "album:\(album.id)"
        case let .playlist(playlist): "playlist:\(playlist.id)"
        }
    }
}

/// Pins on Home, persisted under `pinned.v1` as `[PinnedItem]`, newest first.
@MainActor
@Observable
public final class PinnedHomeStore {
    public private(set) var items: [PinnedItem] = []
    /// Pins that still exist, sorted by last played (newest first), then
    /// name, as on the web Home page.
    public private(set) var resolved: [PinnedContent] = []

    @ObservationIgnored public let preferences: PreferencesService
    @ObservationIgnored public let repository: LibraryRepository

    public init(preferences: PreferencesService, repository: LibraryRepository) {
        self.preferences = preferences
        self.repository = repository
    }

    /// Reads the stored pins. Call once at start.
    public func load() {}

    public func isPinned(_ itemId: String, kind: PinnedItem.Kind) -> Bool {
        items.contains { $0.itemId == itemId && $0.kind == kind }
    }

    /// Adds the pin at the front. Pinning again has no effect.
    public func pin(_ itemId: String, kind: PinnedItem.Kind) {}

    public func unpin(_ itemId: String, kind: PinnedItem.Kind) {}

    public func toggle(_ itemId: String, kind: PinnedItem.Kind) {}

    /// Refreshes `resolved` from the library.
    public func resolve() async {}
}

// MARK: - Favorites

/// What a favorite refers to.
public enum FavoriteKind: String, Hashable, Sendable {
    case song
    case album
    case artist
}

/// Starred songs, albums and artists. Toggles apply immediately, are sent to
/// the server, and roll back with an error toast when the server rejects
/// them. The local library is updated so offline lists stay consistent.
@MainActor
@Observable
public final class FavoritesStore {
    public private(set) var songIds: Set<String> = []
    public private(set) var albumIds: Set<String> = []
    public private(set) var artistIds: Set<String> = []
    /// Increments after every change, for lists that should reload.
    public private(set) var revision = 0

    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public weak var toasts: ToastCenter?

    public init(api: any SubsonicAPI, library: LibraryService, toasts: ToastCenter? = nil) {
        self.api = api
        self.library = library
        self.toasts = toasts
    }

    /// Loads starred ids from the local library, then from `getStarred2`
    /// when online.
    public func load() async {}

    public func isFavorite(_ kind: FavoriteKind, id: String) -> Bool {
        switch kind {
        case .song: songIds.contains(id)
        case .album: albumIds.contains(id)
        case .artist: artistIds.contains(id)
        }
    }

    public func toggle(_ kind: FavoriteKind, id: String) async {}

    public func setFavorite(_ kind: FavoriteKind, id: String, isFavorite: Bool) async {}

    /// Stars or unstars several songs at once.
    public func setFavorite(songIds: [String], isFavorite: Bool) async {}
}

// MARK: - Playlists

/// The user's playlists and playlist editing.
@MainActor
@Observable
public final class PlaylistsStore {
    public private(set) var playlists: [Playlist] = []
    public private(set) var phase: LoadPhase = .idle
    /// Increments after an edit so open playlist screens reload.
    public private(set) var revision = 0

    @ObservationIgnored public let repository: LibraryRepository
    @ObservationIgnored public let api: any SubsonicAPI

    public init(repository: LibraryRepository, api: any SubsonicAPI) {
        self.repository = repository
        self.api = api
    }

    public func loadIfNeeded() async {}

    public func reload() async {}

    /// Creates a playlist, optionally with songs, and returns it.
    @discardableResult
    public func create(
        name: String,
        comment: String? = nil,
        isPublic: Bool = false,
        songIds: [String] = []
    ) async throws -> Playlist? {
        throw SubsonicAPIError.unsupported
    }

    public func update(
        _ playlistId: String,
        name: String,
        comment: String?,
        isPublic: Bool
    ) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func delete(_ playlistId: String) async throws {
        throw SubsonicAPIError.unsupported
    }

    /// Appends songs. Returns the ids that were already in the playlist and
    /// were skipped.
    @discardableResult
    public func add(songIds: [String], to playlistId: String) async throws -> [String] {
        throw SubsonicAPIError.unsupported
    }

    /// Removes the entries at `indexes` (positions in the playlist).
    public func remove(indexes: [Int], from playlistId: String) async throws {
        throw SubsonicAPIError.unsupported
    }
}

// MARK: - Radio

/// Internet radio stations stored on the server.
@MainActor
@Observable
public final class RadioStore {
    public private(set) var stations: [RadioStation] = []
    public private(set) var phase: LoadPhase = .idle

    @ObservationIgnored public let api: any SubsonicAPI

    public init(api: any SubsonicAPI) {
        self.api = api
    }

    public func load() async {}

    public func create(name: String, streamUrl: String, homePageUrl: String?) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func update(_ station: RadioStation) async throws {
        throw SubsonicAPIError.unsupported
    }

    public func delete(_ stationId: String) async throws {
        throw SubsonicAPIError.unsupported
    }
}

// MARK: - Listening history

/// Songs the user listened to, newest first (web `player_history`), stored
/// in the native play history so it survives reinstalls of the WebView.
///
/// A song is recorded when playback moves to another song after at least
/// ten seconds of accumulated local playback. Nothing is recorded while
/// controlling another device.
@MainActor
@Observable
public final class ListeningHistoryStore {
    public private(set) var songs: [Song] = []

    @ObservationIgnored public let preferences: PreferencesService
    /// Entries kept; from `HistorySettings.maxSize`.
    @ObservationIgnored public var maxSize = HistorySettings().maxSize

    public init(preferences: PreferencesService) {
        self.preferences = preferences
    }

    public func load() {}

    /// Adds `song` at the front and trims to `maxSize`.
    public func record(_ song: Song) {}

    public func remove(at index: Int) {}

    public func clear() {}

    /// Feeds playback changes. Call on every song, play state or target
    /// change; `now` is injectable for tests.
    public func trackPlayback(
        song: Song?,
        isPlaying: Bool,
        isRemote: Bool,
        now: Date = Date()
    ) {}
}
