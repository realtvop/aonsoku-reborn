package github.realtvop.aonsoku.settings

import github.realtvop.aonsoku.theme.darkThemeIds
import github.realtvop.aonsoku.theme.lightThemeIds
import org.json.JSONObject

/**
 * One-time import of the preferences persisted by the former WebView app.
 * Each store was saved as a zustand document (`{"state": …, "version": n}`)
 * under its own key; anything missing or malformed keeps the native default.
 */
object LegacySettingsImporter {
    fun import(stored: Map<String, String>): AppSettings {
        var settings = AppSettings()

        state(stored, "theme_store")?.let { theme ->
            settings = settings.copy(
                themeMode = when (theme.optString("themeMode")) {
                    "light" -> ThemeMode.Light
                    "dark" -> ThemeMode.Dark
                    else -> ThemeMode.System
                },
                lightTheme = theme.optString("lightTheme")
                    .takeIf { it in lightThemeIds } ?: settings.lightTheme,
                darkTheme = theme.optString("darkTheme")
                    .takeIf { it in darkThemeIds } ?: settings.darkTheme,
                materialYou = theme.optBoolean("materialYouEnabled", false),
            )
        }

        state(stored, "lang_store")?.let { lang ->
            settings = settings.copy(language = lang.optString("langCode"))
        }

        state(stored, "app_store")?.let { app ->
            val pages = app.optJSONObject("pages")
            val data = app.optJSONObject("data")
            settings = settings.copy(
                hideRadios = pages?.optBoolean("hideRadiosSection", true) ?: true,
                server = ServerUrlSettings(
                    primaryUrl = data?.optString("primaryUrl").orEmpty()
                        .ifEmpty { data?.optString("url").orEmpty() },
                    fallbackUrl = data?.optString("fallbackUrl").orEmpty(),
                    activeServerType = data?.optString("activeServerType")
                        ?.takeIf { it == "primary" || it == "fallback" },
                ),
            )
        }

        state(stored, "player_store")?.optJSONObject("settings")?.let { player ->
            val replayGain = player.optJSONObject("replayGain")?.optJSONObject("values")
            val lyrics = player.optJSONObject("lyrics")
            settings = settings.copy(
                useAlbumCoverForSongs = player.optJSONObject("coverArt")
                    ?.optBoolean("useAlbumCoverForSongs", false) ?: false,
                songColorIntensity = player.optJSONObject("colors")
                    ?.optDouble("currentSongColorIntensity", 0.65)
                    ?.toFloat()?.coerceIn(0f, 1f) ?: 0.65f,
                hapticFeedback = player.optJSONObject("hapticFeedback")
                    ?.optBoolean("hapticFeedbackEnabled", true) ?: true,
                lrcLibEnabled = player.optJSONObject("privacy")
                    ?.optBoolean("lrcLibEnabled", true) ?: true,
                replayGain = replayGain?.let {
                    ReplayGainSettings(
                        enabled = it.optBoolean("enabled", false),
                        type = if (it.optString("type") == "album") {
                            ReplayGainType.Album
                        } else {
                            ReplayGainType.Track
                        },
                        preAmp = it.optInt("preAmp", 0).coerceIn(-15, 15),
                        defaultGain = it.optInt("defaultGain", -6).coerceIn(-10, -1),
                    )
                } ?: settings.replayGain,
                lyrics = lyrics?.let(::importLyrics) ?: settings.lyrics,
            )
        }

        state(stored, "cache_settings")?.let { cache ->
            val values = cache.optJSONObject("settings")
            val rules = values?.optJSONObject("smartRules")
            settings = settings.copy(
                cache = CacheSettings(
                    assetsQuota = values?.optLong(
                        "assetsQuota",
                        CacheSettings.DEFAULT_ASSETS_QUOTA,
                    ) ?: CacheSettings.DEFAULT_ASSETS_QUOTA,
                    lruQuota = values?.optLong(
                        "lruQuota",
                        CacheSettings.DEFAULT_LRU_QUOTA,
                    ) ?: CacheSettings.DEFAULT_LRU_QUOTA,
                    smartRules = SmartDownloadRules(
                        enabled = rules?.optBoolean("enabled", false) ?: false,
                        favoriteSongs = rules?.optBoolean("favoriteSongs", true) ?: true,
                        favoritePlaylists = rules?.optBoolean("favoritePlaylists", true) ?: true,
                    ),
                    syncCoverArt = values?.optBoolean("syncCoverArt", false) ?: false,
                    coverArtConcurrency = (
                        values?.optInt(
                            "coverArtConcurrency",
                            CacheSettings.COVER_ART_CONCURRENCY_DEFAULT,
                        ) ?: CacheSettings.COVER_ART_CONCURRENCY_DEFAULT
                        ).coerceIn(
                        CacheSettings.COVER_ART_CONCURRENCY_MIN,
                        CacheSettings.COVER_ART_CONCURRENCY_MAX,
                    ),
                    lastSyncedAt = cache.optJSONObject("status")
                        ?.takeIf { !it.isNull("lastSyncedAt") }
                        ?.optLong("lastSyncedAt"),
                ),
            )
        }

        state(stored, "pinned_home_store")?.optJSONArray("items")?.let { items ->
            val pinned = (0 until items.length()).mapNotNull { index ->
                val item = items.optJSONObject(index) ?: return@mapNotNull null
                val id = item.optString("id")
                val type = item.optString("type")
                if (id.isEmpty() || type !in setOf("album", "playlist")) {
                    null
                } else {
                    PinnedHomeItem(id, type)
                }
            }
            settings = settings.copy(pinnedHome = pinned)
        }

        state(stored, "player_history")?.let { history ->
            settings = settings.copy(
                playHistoryMaxSize = history.optInt("maxSize", 100).coerceIn(10, 1000),
            )
        }

        return settings
    }

    /** Songs recorded by the web play-history store, newest first. */
    fun importPlayHistory(stored: Map<String, String>): List<String> {
        val history = state(stored, "player_history")?.optJSONArray("history")
            ?: return emptyList()
        return (0 until history.length()).mapNotNull { index ->
            history.optJSONObject(index)?.toString()
        }
    }

    private fun importLyrics(lyrics: JSONObject): LyricsSettings {
        val defaults = LyricsSettings()
        val priority = lyrics.optJSONArray("sourcePriority")?.let { array ->
            (0 until array.length()).mapNotNull { index ->
                when (array.optString(index)) {
                    "navidrome" -> LyricsSource.Navidrome
                    "lrclib" -> LyricsSource.LrcLib
                    "custom" -> LyricsSource.Custom
                    else -> null
                }
            }.distinct()
        }?.takeIf { it.size == defaults.sourcePriority.size } ?: defaults.sourcePriority

        val selected = buildMap {
            val entries = lyrics.optJSONObject("selectedCustomLyrics") ?: return@buildMap
            for (songKey in entries.keys()) {
                val entry = entries.optJSONObject(songKey) ?: continue
                put(
                    songKey,
                    SelectedCustomLyrics(
                        key = entry.optString("key"),
                        title = entry.optString("title").takeIf { it.isNotEmpty() },
                        artist = entry.optString("artist").takeIf { it.isNotEmpty() },
                        album = entry.optString("album").takeIf { it.isNotEmpty() },
                        disabled = entry.optBoolean("disabled", false),
                        offset = entry.optDouble("offset", 0.0).takeIf { it.isFinite() } ?: 0.0,
                    ),
                )
            }
        }

        return LyricsSettings(
            preferSynced = lyrics.optBoolean("preferSyncedLyrics", defaults.preferSynced),
            showTranslation = lyrics.optBoolean("showTranslation", defaults.showTranslation),
            sourcePriority = priority,
            customServerEnabled = lyrics.optBoolean("customServerEnabled", false),
            customServerUrl = lyrics.optString("customServerUrl"),
            customServerPassword = decodeStoredPassword(lyrics.optString("customServerPassword")),
            // Lyrics bodies were stored in the WebView's IndexedDB and cannot
            // be read natively, so only offsets and "lyrics off" survive.
            selected = selected.filterValues { it.disabled || it.offset != 0.0 }
                .mapValues { (_, value) -> value.copy(key = "") },
        )
    }

    /** The web app stored secrets as `enc:` followed by hex-encoded UTF-16 code units. */
    internal fun decodeStoredPassword(value: String): String {
        if (!value.startsWith("enc:")) return value
        val hex = value.removePrefix("enc:")
        if (hex.length % 2 != 0) return ""
        return runCatching {
            hex.chunked(2).map { it.toInt(16).toChar() }.joinToString("")
        }.getOrDefault("")
    }

    private fun state(stored: Map<String, String>, key: String): JSONObject? {
        val raw = stored[key] ?: return null
        return runCatching { JSONObject(raw).optJSONObject("state") }.getOrNull()
    }
}
