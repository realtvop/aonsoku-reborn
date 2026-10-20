import Foundation
import Observation

/// Lyrics for the playing song (web `src/service/lyrics.ts`): sources in the
/// configured priority, the custom lyrics server, per-song candidate
/// selection, hiding and timing offset.
///
/// Selections are stored under `lyrics.selections.v1`, keyed by the song key
/// (`[path, artist, title, album].joined("\u{1F}")`), at most 50 songs.
@MainActor
@Observable
public final class LyricsStore {
    public private(set) var state = LyricsLoadState.idle
    /// The song `state` belongs to.
    public private(set) var songId: String?
    /// The current song's selection; `.init()` when it has none.
    public private(set) var selection = CustomLyricsSelection()

    @ObservationIgnored public let api: any SubsonicAPI
    @ObservationIgnored public let library: LibraryService
    @ObservationIgnored public let settings: SettingsStore
    @ObservationIgnored public let preferences: PreferencesService
    /// The signed-in server type, for the LMS artist rule.
    @ObservationIgnored public var serverType: @MainActor () -> String? = { nil }
    @ObservationIgnored public var urlSession: URLSession = .shared

    public init(
        api: any SubsonicAPI,
        library: LibraryService,
        settings: SettingsStore,
        preferences: PreferencesService
    ) {
        self.api = api
        self.library = library
        self.settings = settings
        self.preferences = preferences
    }

    /// Loads lyrics for `song` unless they are already loaded or loading.
    /// nil clears the state.
    public func load(for song: Song?) async {}

    /// Loads again, bypassing the in-memory cache.
    public func reload() async {}

    /// The line to highlight at a playback position, with the offset applied.
    public func lineIndex(at position: TimeInterval) -> Int? {
        state.lyrics?.lineIndex(at: position + selection.offset)
    }

    /// Searches the custom lyrics server. Empty when it is not configured.
    public func searchCandidates(title: String, artist: String) async throws -> [CustomLyricsCandidate] {
        []
    }

    /// Uses `candidate` for the current song and reloads.
    public func select(_ candidate: CustomLyricsCandidate) async {}

    /// Returns the current song to automatic sources, keeping its offset.
    public func resetSelection() async {}

    /// Hides or shows lyrics for the current song.
    public func setDisabled(_ disabled: Bool) async {}

    /// Seconds added to the playback position, clamped to
    /// `CustomLyricsSelection.offsetRange`.
    public func setOffset(_ offset: Double) {}
}
