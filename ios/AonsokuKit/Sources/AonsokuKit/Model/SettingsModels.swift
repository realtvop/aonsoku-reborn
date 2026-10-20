import Foundation

// User settings. Each group mirrors a web settings page and keeps the web
// defaults (`src/store/player/initial-state.ts`, `src/store/theme.store.ts`,
// `src/store/cache.store.ts`, `src/store/app.store.ts`). Decoding tolerates
// missing keys so settings written by an older build keep their values and
// pick up defaults for new fields.

// MARK: - Appearance

public enum ThemeMode: String, Codable, Hashable, Sendable, CaseIterable {
    case light
    case dark
    case system

    /// Translation key for the mode name.
    public var labelKey: String {
        switch self {
        case .light: "theme.modeLight"
        case .dark: "theme.modeDark"
        case .system: "theme.modeSystem"
        }
    }
}

/// Named color themes. Raw values match the web `Theme` enum
/// (`src/types/themeContext.ts`) and the `theme.<raw value>` translation keys.
public enum AppTheme: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case light
    case dark
    case black
    case oneDark = "one-dark"
    case nightOwlLight = "night-owl-light"
    case marmaladeBeaver = "marmalade-beaver"
    case noctisLilac = "noctis-lilac"
    case materialTheme = "material-theme"
    case monokaiPro = "monokai-pro"
    case githubDark = "github-dark"
    case shadesOfPurple = "shades-of-purple"
    case beardedSolarized = "bearded-solarized"
    case catppuccinMocha = "catppuccin-mocha"
    case nuclearDark = "nuclear-dark"
    case achiever
    case dracula
    case discord
    case tinaciousDesign = "tinacious-design"
    case vueDark = "vue-dark"
    case vimDarkSoft = "vim-dark-soft"

    public var id: String { rawValue }

    public var labelKey: String { "theme.\(rawValue)" }

    public static let lightThemes: [AppTheme] = [
        .light, .nightOwlLight, .noctisLilac, .achiever, .tinaciousDesign,
    ]

    public static let darkThemes: [AppTheme] = [
        .dark, .black, .oneDark, .marmaladeBeaver, .materialTheme, .monokaiPro,
        .githubDark, .shadesOfPurple, .beardedSolarized, .catppuccinMocha,
        .nuclearDark, .dracula, .discord, .vueDark, .vimDarkSoft,
    ]

    public var isDark: Bool { Self.darkThemes.contains(self) }
}

public struct AppearanceSettings: Codable, Hashable, Sendable {
    public var themeMode: ThemeMode = .system
    public var lightTheme: AppTheme = .light
    public var darkTheme: AppTheme = .dark
    /// Strength of the cover colors behind Now Playing, 0.3...1 (web
    /// `player_store` `settings.colors.currentSongColorIntensity`).
    public var nowPlayingColorIntensity = 0.65

    public static let colorIntensityRange: ClosedRange<Double> = 0.3...1

    public init(
        themeMode: ThemeMode = .system,
        lightTheme: AppTheme = .light,
        darkTheme: AppTheme = .dark,
        nowPlayingColorIntensity: Double = 0.65
    ) {
        self.themeMode = themeMode
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.nowPlayingColorIntensity = nowPlayingColorIntensity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        themeMode = c.value(.themeMode, default: d.themeMode)
        lightTheme = c.value(.lightTheme, default: d.lightTheme)
        darkTheme = c.value(.darkTheme, default: d.darkTheme)
        nowPlayingColorIntensity = c.value(
            .nowPlayingColorIntensity,
            default: d.nowPlayingColorIntensity
        )
    }
}

// MARK: - Playback

public struct PlaybackSettings: Codable, Hashable, Sendable {
    /// Sensory feedback on controls and gestures.
    public var hapticFeedback = true
    /// Opens Now Playing when playback of a new queue starts (web
    /// `autoFullscreen`).
    public var autoOpenNowPlaying = false
    /// Shows the album cover instead of per-song artwork, and syncs only
    /// album covers.
    public var useAlbumCoverForSongs = false

    public init(
        hapticFeedback: Bool = true,
        autoOpenNowPlaying: Bool = false,
        useAlbumCoverForSongs: Bool = false
    ) {
        self.hapticFeedback = hapticFeedback
        self.autoOpenNowPlaying = autoOpenNowPlaying
        self.useAlbumCoverForSongs = useAlbumCoverForSongs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        hapticFeedback = c.value(.hapticFeedback, default: d.hapticFeedback)
        autoOpenNowPlaying = c.value(.autoOpenNowPlaying, default: d.autoOpenNowPlaying)
        useAlbumCoverForSongs = c.value(
            .useAlbumCoverForSongs,
            default: d.useAlbumCoverForSongs
        )
    }
}

public enum ReplayGainMode: String, Codable, Hashable, Sendable, CaseIterable {
    case track
    case album
}

public struct ReplayGainSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var mode: ReplayGainMode = .track
    /// Decibels added to every gain, -15...15.
    public var preAmp: Double = 0
    /// Decibels used when a song has no ReplayGain tags, -10...-1.
    public var defaultGain: Double = -6

    public static let preAmpRange: ClosedRange<Double> = -15...15
    public static let defaultGainRange: ClosedRange<Double> = -10 ... -1

    public init(
        enabled: Bool = false,
        mode: ReplayGainMode = .track,
        preAmp: Double = 0,
        defaultGain: Double = -6
    ) {
        self.enabled = enabled
        self.mode = mode
        self.preAmp = preAmp
        self.defaultGain = defaultGain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, default: d.enabled)
        mode = c.value(.mode, default: d.mode)
        preAmp = c.value(.preAmp, default: d.preAmp)
        defaultGain = c.value(.defaultGain, default: d.defaultGain)
    }
}

// MARK: - Lyrics

public struct LyricsSettings: Codable, Hashable, Sendable {
    /// Picks the first synced result over an earlier unsynced one.
    public var preferSyncedLyrics = false
    public var showTranslation = true
    /// Source order; always contains every source exactly once.
    public var sourcePriority: [LyricsSource] = [.navidrome, .lrclib, .custom]
    public var customServerEnabled = false
    public var customServerUrl = ""
    /// Sent as the `Authorization` header to the custom server.
    public var customServerPassword = ""

    public init(
        preferSyncedLyrics: Bool = false,
        showTranslation: Bool = true,
        sourcePriority: [LyricsSource] = [.navidrome, .lrclib, .custom],
        customServerEnabled: Bool = false,
        customServerUrl: String = "",
        customServerPassword: String = ""
    ) {
        self.preferSyncedLyrics = preferSyncedLyrics
        self.showTranslation = showTranslation
        self.sourcePriority = sourcePriority
        self.customServerEnabled = customServerEnabled
        self.customServerUrl = customServerUrl
        self.customServerPassword = customServerPassword
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        preferSyncedLyrics = c.value(.preferSyncedLyrics, default: d.preferSyncedLyrics)
        showTranslation = c.value(.showTranslation, default: d.showTranslation)
        sourcePriority = Self.normalizedPriority(
            c.value(.sourcePriority, default: d.sourcePriority)
        )
        customServerEnabled = c.value(.customServerEnabled, default: d.customServerEnabled)
        customServerUrl = c.value(.customServerUrl, default: d.customServerUrl)
        customServerPassword = c.value(.customServerPassword, default: d.customServerPassword)
    }

    /// Removes duplicates and appends missing sources in default order.
    public static func normalizedPriority(_ sources: [LyricsSource]) -> [LyricsSource] {
        var seen = Set<LyricsSource>()
        var result = sources.filter { seen.insert($0).inserted }
        for source in LyricsSource.allCases where !seen.contains(source) {
            result.append(source)
        }
        return result
    }
}

// MARK: - Storage

/// Smart download rules (web `smartDownload`).
public struct SmartDownloadRules: Codable, Hashable, Sendable {
    public var enabled = false
    public var favoriteSongs = true
    public var favoritePlaylists = true

    public init(enabled: Bool = false, favoriteSongs: Bool = true, favoritePlaylists: Bool = true) {
        self.enabled = enabled
        self.favoriteSongs = favoriteSongs
        self.favoritePlaylists = favoritePlaylists
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, default: d.enabled)
        favoriteSongs = c.value(.favoriteSongs, default: d.favoriteSongs)
        favoritePlaylists = c.value(.favoritePlaylists, default: d.favoritePlaylists)
    }
}

public struct CacheSettings: Codable, Hashable, Sendable {
    /// Bytes for covers, lyrics and other assets; 0 means unlimited.
    public var assetsQuota: Int64 = 512 * 1024 * 1024
    /// Bytes for the least-recently-used stream cache; 0 means unlimited.
    public var lruQuota: Int64 = 1024 * 1024 * 1024
    public var smartRules = SmartDownloadRules()
    /// Downloads cover art during library sync.
    public var syncCoverArt = false
    /// Parallel cover downloads during sync, 1...8.
    public var coverArtConcurrency = 4

    /// Quota choices offered in Settings, in bytes; 0 is Unlimited.
    public static let quotaOptions: [Int64] = [
        256 * 1024 * 1024,
        512 * 1024 * 1024,
        1024 * 1024 * 1024,
        2 * 1024 * 1024 * 1024,
        3 * 1024 * 1024 * 1024,
        5 * 1024 * 1024 * 1024,
        0,
    ]
    public static let coverArtConcurrencyRange: ClosedRange<Int> = 1...8

    public init(
        assetsQuota: Int64 = 512 * 1024 * 1024,
        lruQuota: Int64 = 1024 * 1024 * 1024,
        smartRules: SmartDownloadRules = SmartDownloadRules(),
        syncCoverArt: Bool = false,
        coverArtConcurrency: Int = 4
    ) {
        self.assetsQuota = assetsQuota
        self.lruQuota = lruQuota
        self.smartRules = smartRules
        self.syncCoverArt = syncCoverArt
        self.coverArtConcurrency = coverArtConcurrency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        assetsQuota = c.value(.assetsQuota, default: d.assetsQuota)
        lruQuota = c.value(.lruQuota, default: d.lruQuota)
        smartRules = c.value(.smartRules, default: d.smartRules)
        syncCoverArt = c.value(.syncCoverArt, default: d.syncCoverArt)
        coverArtConcurrency = min(
            max(c.value(.coverArtConcurrency, default: d.coverArtConcurrency), 1),
            8
        )
    }
}

// MARK: - Content, privacy, history

public struct ContentSettings: Codable, Hashable, Sendable {
    /// Hides Radio in Library and Search.
    public var hideRadiosSection = true

    public init(hideRadiosSection: Bool = true) {
        self.hideRadiosSection = hideRadiosSection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideRadiosSection = c.value(.hideRadiosSection, default: true)
    }
}

public struct PrivacySettings: Codable, Hashable, Sendable {
    /// Allows lyrics lookups on lrclib.net.
    public var lrcLibEnabled = true

    public init(lrcLibEnabled: Bool = true) {
        self.lrcLibEnabled = lrcLibEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lrcLibEnabled = c.value(.lrcLibEnabled, default: true)
    }
}

public struct HistorySettings: Codable, Hashable, Sendable {
    /// Songs kept in listening history, 10...1000 in steps of 10.
    public var maxSize = 100

    public static let range: ClosedRange<Int> = 10...1000
    public static let step = 10

    public init(maxSize: Int = 100) {
        self.maxSize = maxSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxSize = min(max(c.value(.maxSize, default: 100), Self.range.lowerBound), Self.range.upperBound)
    }
}

// MARK: - All settings

/// Every user setting, persisted as one JSON document under
/// `SettingsStore.storageKey`.
public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance = AppearanceSettings()
    /// A code from `AppLanguage.all`, or nil to follow the system language.
    public var languageCode: String?
    public var playback = PlaybackSettings()
    public var replayGain = ReplayGainSettings()
    public var lyrics = LyricsSettings()
    public var cache = CacheSettings()
    public var content = ContentSettings()
    public var privacy = PrivacySettings()
    public var history = HistorySettings()

    public init(
        appearance: AppearanceSettings = AppearanceSettings(),
        languageCode: String? = nil,
        playback: PlaybackSettings = PlaybackSettings(),
        replayGain: ReplayGainSettings = ReplayGainSettings(),
        lyrics: LyricsSettings = LyricsSettings(),
        cache: CacheSettings = CacheSettings(),
        content: ContentSettings = ContentSettings(),
        privacy: PrivacySettings = PrivacySettings(),
        history: HistorySettings = HistorySettings()
    ) {
        self.appearance = appearance
        self.languageCode = languageCode
        self.playback = playback
        self.replayGain = replayGain
        self.lyrics = lyrics
        self.cache = cache
        self.content = content
        self.privacy = privacy
        self.history = history
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        appearance = c.value(.appearance, default: d.appearance)
        languageCode = c.value(.languageCode, default: nil)
        playback = c.value(.playback, default: d.playback)
        replayGain = c.value(.replayGain, default: d.replayGain)
        lyrics = c.value(.lyrics, default: d.lyrics)
        cache = c.value(.cache, default: d.cache)
        content = c.value(.content, default: d.content)
        privacy = c.value(.privacy, default: d.privacy)
        history = c.value(.history, default: d.history)
    }
}

// MARK: - Languages

/// A bundled translation. Codes and names match `src/i18n/languages.ts`.
public struct AppLanguage: Identifiable, Hashable, Sendable {
    public var code: String
    public var nativeName: String
    /// ISO 3166 region code of the flag shown next to the name.
    public var flag: String
    /// Translation file name in the bundled `locales` folder, without
    /// extension.
    public var resourceName: String

    public var id: String { code }

    public init(code: String, nativeName: String, flag: String, resourceName: String) {
        self.code = code
        self.nativeName = nativeName
        self.flag = flag
        self.resourceName = resourceName
    }

    /// The flag as an emoji.
    public var flagEmoji: String {
        flag.uppercased().unicodeScalars.compactMap {
            Unicode.Scalar(127_397 + $0.value).map(String.init)
        }.joined()
    }

    public static let fallbackCode = "en-US"

    public static let all: [AppLanguage] = [
        AppLanguage(code: "cs", nativeName: "Čeština", flag: "CZ", resourceName: "cs"),
        AppLanguage(code: "de", nativeName: "Deutsch", flag: "DE", resourceName: "de"),
        AppLanguage(code: "en-US", nativeName: "English (US)", flag: "US", resourceName: "en"),
        AppLanguage(code: "es-ES", nativeName: "Español (España)", flag: "ES", resourceName: "es"),
        AppLanguage(code: "fr", nativeName: "Français", flag: "FR", resourceName: "fr"),
        AppLanguage(code: "fr-CA", nativeName: "Français (Canada)", flag: "CA", resourceName: "fr-CA"),
        AppLanguage(code: "it", nativeName: "Italiano", flag: "IT", resourceName: "it"),
        AppLanguage(code: "ja", nativeName: "日本語", flag: "JP", resourceName: "ja"),
        AppLanguage(code: "ko", nativeName: "한국어", flag: "KR", resourceName: "ko"),
        AppLanguage(code: "ml", nativeName: "മലയാളം", flag: "IN", resourceName: "ml"),
        AppLanguage(code: "pl", nativeName: "Polski", flag: "PL", resourceName: "pl"),
        AppLanguage(code: "pt", nativeName: "Português (Portugal)", flag: "PT", resourceName: "pt"),
        AppLanguage(code: "pt-BR", nativeName: "Português (Brasil)", flag: "BR", resourceName: "pt-BR"),
        AppLanguage(code: "ru", nativeName: "Русский", flag: "RU", resourceName: "ru"),
        AppLanguage(code: "sv", nativeName: "Svenska", flag: "SE", resourceName: "sv"),
        AppLanguage(code: "tr", nativeName: "Türkçe", flag: "TR", resourceName: "tr"),
        AppLanguage(code: "uk", nativeName: "Українська", flag: "UA", resourceName: "uk"),
        AppLanguage(code: "zh-Hans", nativeName: "简体中文", flag: "CN", resourceName: "zh-Hans"),
    ]

    public static func language(code: String) -> AppLanguage? {
        all.first { $0.code == code }
    }
}

// MARK: - Tolerant decoding

extension KeyedDecodingContainer {
    /// Decodes `key`, or returns `fallback` when the key is missing, null or
    /// holds a value of another type.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
