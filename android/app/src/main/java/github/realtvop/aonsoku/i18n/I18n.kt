package github.realtvop.aonsoku.i18n

import android.content.Context
import android.icu.text.PluralRules
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import org.json.JSONObject
import java.util.Locale

/** A language shipped with the app. Mirrors `src/i18n/languages.ts`. */
data class AppLanguage(
    val code: String,
    val nativeName: String,
    val countryCode: String,
    val asset: String,
) {
    val locale: Locale get() = Locale.forLanguageTag(code)

    /** Regional-indicator emoji for [countryCode]. */
    val flag: String
        get() = countryCode.uppercase(Locale.ROOT).map { char ->
            String(Character.toChars(0x1F1E6 + (char - 'A')))
        }.joinToString("")
}

val appLanguages: List<AppLanguage> = listOf(
    AppLanguage("cs", "Čeština", "CZ", "cs"),
    AppLanguage("de", "Deutsch", "DE", "de"),
    AppLanguage("en-US", "English (US)", "US", "en"),
    AppLanguage("es-ES", "Español (España)", "ES", "es"),
    AppLanguage("fr", "Français", "FR", "fr"),
    AppLanguage("fr-CA", "Français (Canada)", "CA", "fr-CA"),
    AppLanguage("it", "Italiano", "IT", "it"),
    AppLanguage("ja", "日本語", "JP", "ja"),
    AppLanguage("ko", "한국어", "KR", "ko"),
    AppLanguage("ml", "മലയാളം", "IN", "ml"),
    AppLanguage("pl", "Polski", "PL", "pl"),
    AppLanguage("pt", "Português (Portugal)", "PT", "pt"),
    AppLanguage("pt-BR", "Português (Brasil)", "BR", "pt-BR"),
    AppLanguage("ru", "Русский", "RU", "ru"),
    AppLanguage("sv", "Svenska", "SE", "sv"),
    AppLanguage("tr", "Türkçe", "TR", "tr"),
    AppLanguage("uk", "Українська", "UA", "uk"),
    AppLanguage("zh-Hans", "简体中文", "CN", "zh-Hans"),
)

const val FALLBACK_LANGUAGE = "en-US"

/**
 * Resolved strings for one language with English as fallback. Keys, `{{name}}`
 * interpolation and `_one`/`_other` plural suffixes follow the i18next format
 * of the shared locale files.
 */
class Translations(
    val language: AppLanguage,
    private val strings: Map<String, String>,
    private val fallback: Map<String, String>,
    /** CLDR plural category ("one", "few", "other", …) for a count. */
    private val pluralCategory: (Int) -> String = icuPluralCategory(language),
) {
    fun has(key: String): Boolean = strings.containsKey(key) || fallback.containsKey(key)

    fun t(key: String, vararg args: Pair<String, Any?>): String =
        interpolate(strings[key] ?: fallback[key] ?: key, args)

    /** Plural lookup: `key_one`, `key_other`, … selected by [count]. */
    fun plural(key: String, count: Int, vararg args: Pair<String, Any?>): String {
        val category = pluralCategory(count)
        val template = strings["${key}_$category"]
            ?: strings["${key}_other"]
            ?: strings[key]
            ?: fallback["${key}_${if (count == 1) "one" else "other"}"]
            ?: fallback["${key}_other"]
            ?: fallback[key]
            ?: key
        return interpolate(template, arrayOf("count" to count, *args))
    }

    /**
     * Relative time such as "5 minutes ago", using the dayjs strings of the
     * locale. With [withoutSuffix] only the amount ("5 minutes") is returned.
     */
    fun fromNow(
        epochMillis: Long,
        now: Long = System.currentTimeMillis(),
        withoutSuffix: Boolean = false,
    ): String {
        val seconds = ((now - epochMillis) / 1000.0).let { kotlin.math.abs(it) }
        val minutes = seconds / 60
        val hours = minutes / 60
        val days = hours / 24
        val months = days / 30.4375
        val (unit, value) = when {
            seconds < 45 -> "s" to 0
            seconds < 90 -> "m" to 1
            minutes < 45 -> "mm" to Math.round(minutes).toInt()
            minutes < 90 -> "h" to 1
            hours < 22 -> "hh" to Math.round(hours).toInt()
            hours < 36 -> "d" to 1
            days < 26 -> "dd" to Math.round(days).toInt()
            days < 46 -> "M" to 1
            months < 11 -> "MM" to Math.round(months).toInt()
            months < 18 -> "y" to 1
            else -> "yy" to Math.round(months / 12).toInt()
        }
        val amount = t("dayjs.relativeTime.$unit").replace("%d", value.toString())
        if (withoutSuffix) return amount
        val frame = if (epochMillis > now) "future" else "past"
        return t("dayjs.relativeTime.$frame").replace("%s", amount)
    }

    private fun interpolate(template: String, args: Array<out Pair<String, Any?>>): String {
        if (args.isEmpty() || !template.contains("{{")) return template
        val values = args.toMap()
        return PLACEHOLDER.replace(template) { match ->
            val name = match.groupValues[1]
            if (values.containsKey(name)) values[name]?.toString().orEmpty() else match.value
        }
    }

    private companion object {
        val PLACEHOLDER = Regex("\\{\\{\\s*([A-Za-z0-9_]+)\\s*\\}\\}")
    }
}

private fun icuPluralCategory(language: AppLanguage): (Int) -> String {
    val rules = PluralRules.forLocale(language.locale)
    return { count -> rules.select(count.toDouble()) }
}

object I18n {
    private val cache = mutableMapOf<String, Map<String, String>>()

    fun languageFor(code: String): AppLanguage =
        appLanguages.firstOrNull { it.code == code } ?: detectSystemLanguage()

    /** Best match for the device locale, falling back to English. */
    fun detectSystemLanguage(locale: Locale = Locale.getDefault()): AppLanguage {
        val tag = locale.toLanguageTag()
        val script = locale.script
        return appLanguages.firstOrNull { it.code.equals(tag, ignoreCase = true) }
            ?: appLanguages.firstOrNull {
                it.locale.language == locale.language &&
                    it.locale.country.isNotEmpty() &&
                    it.locale.country == locale.country
            }
            ?: appLanguages.firstOrNull {
                locale.language == "zh" && it.code == "zh-Hans" && script != "Hant"
            }
            ?: appLanguages.firstOrNull {
                it.locale.language == locale.language && it.locale.country.isEmpty()
            }
            ?: appLanguages.firstOrNull { it.locale.language == locale.language }
            ?: appLanguages.first { it.code == FALLBACK_LANGUAGE }
    }

    fun load(context: Context, code: String): Translations {
        val language = languageFor(code)
        val fallback = strings(context, appLanguages.first { it.code == FALLBACK_LANGUAGE })
        return Translations(language, strings(context, language), fallback)
    }

    @Synchronized
    private fun strings(context: Context, language: AppLanguage): Map<String, String> =
        cache.getOrPut(language.code) {
            runCatching {
                val raw = context.assets.open("i18n/${language.asset}.json")
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
                flatten(JSONObject(raw))
            }.getOrDefault(emptyMap())
        }

    internal fun flatten(json: JSONObject, prefix: String = ""): Map<String, String> {
        val result = HashMap<String, String>()
        for (key in json.keys()) {
            val path = if (prefix.isEmpty()) key else "$prefix.$key"
            when (val value = json.opt(key)) {
                is JSONObject -> result.putAll(flatten(value, path))
                is String -> result[path] = value
            }
        }
        return result
    }
}

val LocalStrings = staticCompositionLocalOf<Translations> {
    error("Translations are not provided")
}

@Composable
@ReadOnlyComposable
fun t(key: String, vararg args: Pair<String, Any?>): String = LocalStrings.current.t(key, *args)

@Composable
@ReadOnlyComposable
fun plural(key: String, count: Int, vararg args: Pair<String, Any?>): String =
    LocalStrings.current.plural(key, count, *args)
