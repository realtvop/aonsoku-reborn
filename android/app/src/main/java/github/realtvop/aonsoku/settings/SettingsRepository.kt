package github.realtvop.aonsoku.settings

import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * Owner of the native app's preferences. They are stored as one JSON document
 * in the shared native preferences store, next to the keys written by the
 * playback service, so settings and playback state share one backing file.
 */
class SettingsRepository(
    private val preferences: PreferencesService,
    private val scope: CoroutineScope,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        coerceInputValues = true
    }
    private val _state = MutableStateFlow(AppSettings())
    private var persistJob: Job? = null

    val state: StateFlow<AppSettings> = _state.asStateFlow()

    val current: AppSettings get() = _state.value

    /**
     * Reads the stored settings. On the first native launch the preferences
     * written by the former WebView app are imported so users keep their
     * theme, language, lyrics, cache choices, and play history.
     */
    suspend fun load() {
        val stored = preferences.getAllPreferences()
        val raw = stored[KEY]
        val loaded = raw?.let(::decode)
        if (loaded != null) {
            _state.value = loaded
            return
        }
        val imported = LegacySettingsImporter.import(stored)
        _state.value = imported
        preferences.setPreference(KEY, json.encodeToString(AppSettings.serializer(), imported))
        importPlayHistory(stored, imported.playHistoryMaxSize)
    }

    private suspend fun importPlayHistory(stored: Map<String, String>, maxSize: Int) {
        val history = LegacySettingsImporter.importPlayHistory(stored)
        if (history.isEmpty() || preferences.getPlayHistory(1).isNotEmpty()) return
        preferences.setPlayHistory(history.take(maxSize))
    }

    fun update(transform: (AppSettings) -> AppSettings) {
        _state.update(transform)
        schedulePersist()
    }

    /** Write pending changes now, for example when the app goes to background. */
    fun flush() {
        persistJob?.cancel()
        persistJob = scope.launch { persist() }
    }

    private fun schedulePersist() {
        persistJob?.cancel()
        persistJob = scope.launch {
            delay(WRITE_DEBOUNCE_MS)
            persist()
        }
    }

    private suspend fun persist() {
        runCatching {
            preferences.setPreference(
                KEY,
                json.encodeToString(AppSettings.serializer(), _state.value),
            )
        }
    }

    private fun decode(raw: String): AppSettings? =
        runCatching { json.decodeFromString(AppSettings.serializer(), raw) }.getOrNull()

    companion object {
        const val KEY = "native_app_settings"
        private const val WRITE_DEBOUNCE_MS = 300L
    }
}
