package github.realtvop.aonsoku.settings

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class ThemeMode {
    @SerialName("light")
    Light,

    @SerialName("dark")
    Dark,

    @SerialName("system")
    System,
}

@Serializable
enum class ReplayGainType {
    @SerialName("track")
    Track,

    @SerialName("album")
    Album,
}

@Serializable
enum class LyricsSource {
    @SerialName("navidrome")
    Navidrome,

    @SerialName("lrclib")
    LrcLib,

    @SerialName("custom")
    Custom,
}

@Serializable
data class ReplayGainSettings(
    val enabled: Boolean = false,
    val type: ReplayGainType = ReplayGainType.Track,
    val preAmp: Int = 0,
    val defaultGain: Int = -6,
)

/** A lyrics candidate the user picked for one song (bodies live in LyricsStore). */
@Serializable
data class SelectedCustomLyrics(
    val key: String = "",
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    val disabled: Boolean = false,
    /** Manual timing offset in seconds; positive delays the lyrics. */
    val offset: Double = 0.0,
    val hasRomaji: Boolean = false,
)

@Serializable
data class LyricsSettings(
    val preferSynced: Boolean = false,
    val showTranslation: Boolean = true,
    val sourcePriority: List<LyricsSource> = listOf(
        LyricsSource.Navidrome,
        LyricsSource.LrcLib,
        LyricsSource.Custom,
    ),
    val customServerEnabled: Boolean = false,
    val customServerUrl: String = "",
    val customServerPassword: String = "",
    val selected: Map<String, SelectedCustomLyrics> = emptyMap(),
)

@Serializable
data class SmartDownloadRules(
    val enabled: Boolean = false,
    val favoriteSongs: Boolean = true,
    val favoritePlaylists: Boolean = true,
)

@Serializable
data class CacheSettings(
    /** Cap for cover art; 0 means unlimited. */
    val assetsQuota: Long = DEFAULT_ASSETS_QUOTA,
    /** Cap for audio cached while listening; 0 means unlimited. */
    val lruQuota: Long = DEFAULT_LRU_QUOTA,
    val smartRules: SmartDownloadRules = SmartDownloadRules(),
    val syncCoverArt: Boolean = false,
    val coverArtConcurrency: Int = COVER_ART_CONCURRENCY_DEFAULT,
    val lastSyncedAt: Long? = null,
) {
    companion object {
        const val DEFAULT_ASSETS_QUOTA = 536_870_912L
        const val DEFAULT_LRU_QUOTA = 1_073_741_824L
        const val COVER_ART_CONCURRENCY_MIN = 1
        const val COVER_ART_CONCURRENCY_DEFAULT = 4
        const val COVER_ART_CONCURRENCY_MAX = 8

        /** Quota choices shared by every pool; 0 renders as "Unlimited". */
        val SIZE_OPTIONS: List<Pair<Long, String>> = listOf(
            268_435_456L to "256 MB",
            536_870_912L to "512 MB",
            1_073_741_824L to "1 GB",
            2_147_483_648L to "2 GB",
            3_221_225_472L to "3 GB",
            5_368_709_120L to "5 GB",
            0L to "",
        )
    }
}

@Serializable
data class PinnedHomeItem(
    val id: String,
    /** "album" or "playlist". */
    val type: String,
)

@Serializable
data class ServerUrlSettings(
    val primaryUrl: String = "",
    val fallbackUrl: String = "",
    /** "primary", "fallback", or null when no server answered. */
    val activeServerType: String? = null,
)

@Serializable
data class AlbumListPreferences(
    val filter: String = "recentlyAdded",
    val yearFilter: String = "newest",
    val genre: String = "",
)

/** Every user preference of the native app. Persisted as one JSON document. */
@Serializable
data class AppSettings(
    val themeMode: ThemeMode = ThemeMode.System,
    val lightTheme: String = "light",
    val darkTheme: String = "dark",
    val materialYou: Boolean = false,
    /** Language code such as "en-US"; empty follows the system locale. */
    val language: String = "",
    val useAlbumCoverForSongs: Boolean = false,
    /** Blend strength of the artwork color in the full-screen player (0..1). */
    val songColorIntensity: Float = 0.65f,
    val hapticFeedback: Boolean = true,
    val replayGain: ReplayGainSettings = ReplayGainSettings(),
    val lyrics: LyricsSettings = LyricsSettings(),
    val lrcLibEnabled: Boolean = true,
    val hideRadios: Boolean = true,
    val playHistoryMaxSize: Int = 100,
    val cache: CacheSettings = CacheSettings(),
    val pinnedHome: List<PinnedHomeItem> = emptyList(),
    val server: ServerUrlSettings = ServerUrlSettings(),
    val albumList: AlbumListPreferences = AlbumListPreferences(),
    val songSort: String = "lastAdded",
)
