package github.realtvop.aonsoku.i18n

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TranslationsTest {
    private val english = appLanguages.first { it.code == "en-US" }

    private fun translations(
        strings: Map<String, String>,
        fallback: Map<String, String> = emptyMap(),
        category: (Int) -> String = { if (it == 1) "one" else "other" },
    ) = Translations(english, strings, fallback, category)

    @Test
    fun flattensNestedLocaleObjectsIntoDottedKeys() {
        val flat = I18n.flatten(
            JSONObject("""{"home":{"pinned":"Pinned"},"a":{"b":{"c":"deep"}},"n":1}"""),
        )

        assertEquals("Pinned", flat["home.pinned"])
        assertEquals("deep", flat["a.b.c"])
        assertFalse(flat.containsKey("n"))
    }

    @Test
    fun interpolatesNamedPlaceholdersAndKeepsUnknownOnes() {
        val strings = translations(mapOf("k" to "Play {{ title }} by {{artist}} {{missing}}"))

        assertEquals(
            "Play Song by Band {{missing}}",
            strings.t("k", "title" to "Song", "artist" to "Band"),
        )
    }

    @Test
    fun fallsBackToEnglishThenToTheKey() {
        val strings = translations(mapOf("a" to "A"), fallback = mapOf("b" to "B"))

        assertEquals("A", strings.t("a"))
        assertEquals("B", strings.t("b"))
        assertEquals("missing.key", strings.t("missing.key"))
        assertTrue(strings.has("b"))
        assertFalse(strings.has("missing.key"))
    }

    @Test
    fun selectsPluralFormsAndInjectsTheCount() {
        val strings = translations(
            mapOf("songs_one" to "{{count}} song", "songs_other" to "{{count}} songs"),
        )

        assertEquals("1 song", strings.plural("songs", 1))
        assertEquals("12 songs", strings.plural("songs", 12))
    }

    @Test
    fun pluralUsesTheOtherFormWhenACategoryIsNotTranslated() {
        val strings = translations(
            mapOf("songs_one" to "{{count}} pieseň", "songs_other" to "{{count}} piesní"),
            category = { "few" },
        )

        assertEquals("3 piesní", strings.plural("songs", 3))
    }

    @Test
    fun pluralFallsBackToEnglishForms() {
        val strings = translations(
            emptyMap(),
            fallback = mapOf("songs_one" to "{{count}} song", "songs_other" to "{{count}} songs"),
            category = { "many" },
        )

        assertEquals("1 song", strings.plural("songs", 1))
        assertEquals("5 songs", strings.plural("songs", 5))
    }

    @Test
    fun formatsRelativeTimeWithTheLocaleStrings() {
        val strings = translations(
            mapOf(
                "dayjs.relativeTime.past" to "%s ago",
                "dayjs.relativeTime.future" to "in %s",
                "dayjs.relativeTime.s" to "a few seconds",
                "dayjs.relativeTime.mm" to "%d minutes",
                "dayjs.relativeTime.h" to "1 hour",
                "dayjs.relativeTime.dd" to "%d days",
            ),
        )
        val now = 1_000_000_000L

        assertEquals("a few seconds ago", strings.fromNow(now - 10_000, now))
        assertEquals("5 minutes ago", strings.fromNow(now - 5 * 60_000, now))
        assertEquals("1 hour ago", strings.fromNow(now - 60 * 60_000, now))
        assertEquals("3 days ago", strings.fromNow(now - 3 * 24 * 3_600_000L, now))
        assertEquals("in 5 minutes", strings.fromNow(now + 5 * 60_000, now))
    }

    @Test
    fun matchesSystemLocalesToShippedLanguages() {
        fun detect(tag: String) = I18n.detectSystemLanguage(java.util.Locale.forLanguageTag(tag)).code

        assertEquals("en-US", detect("en-GB"))
        assertEquals("pt-BR", detect("pt-BR"))
        assertEquals("pt", detect("pt-PT"))
        assertEquals("fr-CA", detect("fr-CA"))
        assertEquals("fr", detect("fr-FR"))
        assertEquals("zh-Hans", detect("zh-CN"))
        assertEquals("es-ES", detect("es-MX"))
        assertEquals("en-US", detect("xx"))
    }
}
