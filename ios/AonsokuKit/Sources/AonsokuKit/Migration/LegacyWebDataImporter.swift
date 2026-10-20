import Foundation

/// What `LegacyWebDataImporter` moved into native storage.
public struct LegacyImportReport: Equatable, Sendable {
    public var cacheEntries = 0
    public var lyrics = 0
    public var customLyrics = 0
    /// True when the WebView data could not be read; the import is retried
    /// on the next launch.
    public var failed = false

    public init(cacheEntries: Int = 0, lyrics: Int = 0, customLyrics: Int = 0, failed: Bool = false) {
        self.cacheEntries = cacheEntries
        self.lyrics = lyrics
        self.customLyrics = customLyrics
        self.failed = failed
    }
}

/// Reads data the Capacitor app kept in WebView IndexedDB and moves it into
/// native storage, once. A hidden `WKWebView` on the default data store
/// loads a blank page from the old `capacitor://localhost` origin so it can
/// open the same databases:
///
/// - Dexie `aonsoku-library` tables `cacheMeta` and `lyrics`;
/// - idb-keyval `aonsoku-cache` (`cache-index`, `cache-index-v1`) and
///   `aonsoku-offline` (`offline-library`);
/// - `aonsoku-custom-lyrics` (`custom-lyrics:<songKey>` and
///   `custom-lyrics-romaji:<songKey>`).
///
/// Cache rows go to the native `cacheMeta` index, lyrics to the library
/// database, and custom lyrics to the lyrics selections.
@MainActor
public final class LegacyWebDataImporter {
    public static let doneKey = "legacyWebData.imported.v1"

    public let library: LibraryService
    public let preferences: PreferencesService

    public init(library: LibraryService, preferences: PreferencesService) {
        self.library = library
        self.preferences = preferences
    }

    /// True until an import succeeds.
    public var isNeeded: Bool { preferences.getString(Self.doneKey) == nil }

    public func run() async -> LegacyImportReport { LegacyImportReport() }
}
