package github.realtvop.aonsoku.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacySettingsImporterTest {
    @Test
    fun returnsDefaultsWhenNothingWasStored() {
        assertEquals(AppSettings(), LegacySettingsImporter.import(emptyMap()))
    }

    @Test
    fun ignoresMalformedDocuments() {
        val settings = LegacySettingsImporter.import(
            mapOf("theme_store" to "not json", "player_store" to """{"state":null}"""),
        )

        assertEquals(AppSettings(), settings)
    }

    @Test
    fun importsRememberedAlbumListFilter() {
        val settings = LegacySettingsImporter.import(
            mapOf("albums-list-filter" to "byYear", "albums-list-year" to "newest"),
        )

        assertEquals("byYear", settings.albumList.filter)
        assertEquals("newest", settings.albumList.yearFilter)
    }

    @Test
    fun ignoresAlbumFiltersThatNeedMoreContext() {
        val settings = LegacySettingsImporter.import(
            mapOf("albums-list-filter" to "byGenre", "albums-list-year" to "sideways"),
        )

        assertEquals(AlbumListPreferences(), settings.albumList)
    }

    @Test
    fun importsThemeLanguageAndContentPreferences() {
        val settings = LegacySettingsImporter.import(
            mapOf(
                "theme_store" to """{"state":{"themeMode":"dark","lightTheme":"achiever",
                    "darkTheme":"dracula","materialYouEnabled":true},"version":3}""",
                "lang_store" to """{"state":{"langCode":"zh-Hans"},"version":1}""",
                "app_store" to """{"state":{"pages":{"hideRadiosSection":false},
                    "data":{"primaryUrl":"https://music.example","fallbackUrl":"http://10.0.0.2:4533",
                    "activeServerType":"fallback"}},"version":1}""",
            ),
        )

        assertEquals(ThemeMode.Dark, settings.themeMode)
        assertEquals("achiever", settings.lightTheme)
        assertEquals("dracula", settings.darkTheme)
        assertTrue(settings.materialYou)
        assertEquals("zh-Hans", settings.language)
        assertFalse(settings.hideRadios)
        assertEquals("https://music.example", settings.server.primaryUrl)
        assertEquals("http://10.0.0.2:4533", settings.server.fallbackUrl)
        assertEquals("fallback", settings.server.activeServerType)
    }

    @Test
    fun rejectsThemesThatDoNotBelongToTheirGroup() {
        val settings = LegacySettingsImporter.import(
            mapOf(
                "theme_store" to
                    """{"state":{"themeMode":"system","lightTheme":"dracula","darkTheme":"nope"}}""",
            ),
        )

        assertEquals(ThemeMode.System, settings.themeMode)
        assertEquals("light", settings.lightTheme)
        assertEquals("dark", settings.darkTheme)
    }

    @Test
    fun importsPlayerSettings() {
        val settings = LegacySettingsImporter.import(
            mapOf(
                "player_store" to """{"state":{"settings":{
                    "coverArt":{"useAlbumCoverForSongs":true},
                    "colors":{"currentSongColorIntensity":0.4},
                    "hapticFeedback":{"hapticFeedbackEnabled":false},
                    "privacy":{"lrcLibEnabled":false},
                    "replayGain":{"values":{"enabled":true,"type":"album","preAmp":3,"defaultGain":-4}},
                    "lyrics":{"preferSyncedLyrics":true,"showTranslation":false,
                        "sourcePriority":["custom","navidrome","lrclib"],
                        "customServerEnabled":true,"customServerUrl":"https://lyrics.example",
                        "customServerPassword":"enc:736563726574",
                        "selectedCustomLyrics":{
                            "song-a":{"key":"candidate-1","title":"A"},
                            "song-b":{"key":"","disabled":true},
                            "song-c":{"key":"candidate-3","offset":1.5}}}
                }},"version":6}""",
            ),
        )

        assertTrue(settings.useAlbumCoverForSongs)
        assertEquals(0.4f, settings.songColorIntensity, 0.0001f)
        assertFalse(settings.hapticFeedback)
        assertFalse(settings.lrcLibEnabled)
        assertEquals(ReplayGainSettings(true, ReplayGainType.Album, 3, -4), settings.replayGain)
        assertTrue(settings.lyrics.preferSynced)
        assertFalse(settings.lyrics.showTranslation)
        assertEquals(
            listOf(LyricsSource.Custom, LyricsSource.Navidrome, LyricsSource.LrcLib),
            settings.lyrics.sourcePriority,
        )
        assertTrue(settings.lyrics.customServerEnabled)
        assertEquals("https://lyrics.example", settings.lyrics.customServerUrl)
        assertEquals("secret", settings.lyrics.customServerPassword)
        // Candidate bodies lived in the WebView; only offsets and "off" survive.
        assertNull(settings.lyrics.selected["song-a"])
        assertTrue(settings.lyrics.selected.getValue("song-b").disabled)
        assertEquals(1.5, settings.lyrics.selected.getValue("song-c").offset, 0.0)
        assertEquals("", settings.lyrics.selected.getValue("song-c").key)
    }

    @Test
    fun keepsTheDefaultLyricsPriorityWhenTheStoredOneIsIncomplete() {
        val settings = LegacySettingsImporter.import(
            mapOf(
                "player_store" to
                    """{"state":{"settings":{"lyrics":{"sourcePriority":["lrclib","lrclib"]}}}}""",
            ),
        )

        assertEquals(LyricsSettings().sourcePriority, settings.lyrics.sourcePriority)
    }

    @Test
    fun importsCacheSettingsAndClampsConcurrency() {
        val settings = LegacySettingsImporter.import(
            mapOf(
                "cache_settings" to """{"state":{"settings":{"assetsQuota":0,
                    "lruQuota":268435456,"smartRules":{"enabled":true,"favoriteSongs":false},
                    "syncCoverArt":true,"coverArtConcurrency":99},
                    "status":{"lastSyncedAt":1760000000000}}}""",
            ),
        )

        assertEquals(0L, settings.cache.assetsQuota)
        assertEquals(268_435_456L, settings.cache.lruQuota)
        assertEquals(SmartDownloadRules(true, false, true), settings.cache.smartRules)
        assertTrue(settings.cache.syncCoverArt)
        assertEquals(CacheSettings.COVER_ART_CONCURRENCY_MAX, settings.cache.coverArtConcurrency)
        assertEquals(1_760_000_000_000L, settings.cache.lastSyncedAt)
    }

    @Test
    fun importsPinnedItemsAndHistory() {
        val stored = mapOf(
            "pinned_home_store" to """{"state":{"items":[{"id":"al-1","type":"album"},
                {"id":"pl-1","type":"playlist"},{"id":"x","type":"artist"},{"type":"album"}]}}""",
            "player_history" to
                """{"state":{"maxSize":250,"history":[{"id":"s1","title":"One"},{"id":"s2"}]}}""",
        )

        val settings = LegacySettingsImporter.import(stored)
        val history = LegacySettingsImporter.importPlayHistory(stored)

        assertEquals(
            listOf(PinnedHomeItem("al-1", "album"), PinnedHomeItem("pl-1", "playlist")),
            settings.pinnedHome,
        )
        assertEquals(250, settings.playHistoryMaxSize)
        assertEquals(2, history.size)
        assertTrue(history.first().contains("\"s1\""))
    }

    @Test
    fun decodesStoredPasswords() {
        assertEquals("plain", LegacySettingsImporter.decodeStoredPassword("plain"))
        assertEquals("abc", LegacySettingsImporter.decodeStoredPassword("enc:616263"))
        assertEquals("", LegacySettingsImporter.decodeStoredPassword("enc:6162f"))
        assertEquals("", LegacySettingsImporter.decodeStoredPassword("enc:zz"))
    }
}
