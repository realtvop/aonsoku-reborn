package github.realtvop.aonsoku.plugins.preferences

import android.content.Context
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

data class PreferenceChange(
    val key: String?,
    val value: String?,
    val preferences: Map<String, String>,
)

/** Application-scoped typed owner of native preferences and their change stream. */
class PreferencesService private constructor(context: Context) {
    private val store = NativePreferencesStore(context.applicationContext)
    private val _changes = MutableSharedFlow<PreferenceChange>(
        extraBufferCapacity = 32,
    )

    val changes: SharedFlow<PreferenceChange> = _changes.asSharedFlow()

    suspend fun getAllPreferences(): Map<String, String> = store.getAllPreferences()

    suspend fun setPreferences(preferences: Map<String, String>) {
        store.setPreferences(preferences)
        emitChange(key = null, value = null)
    }

    suspend fun setPreference(key: String, value: String) {
        store.setPreference(key, value)
        emitChange(key, value)
    }

    suspend fun deletePreference(key: String) {
        store.deletePreference(key)
        emitChange(key, null)
    }

    suspend fun getQueueState(): String? = store.getQueueState()

    suspend fun setQueueState(state: String) {
        store.setQueueState(state)
        emitChange("queue_state", state)
    }

    suspend fun getPlayHistory(limit: Int): List<String> = store.getPlayHistory(limit)

    suspend fun addToPlayHistory(song: String, maxSize: Int) {
        store.addToPlayHistory(song, maxSize)
        emitChange("play_history", null)
    }

    suspend fun clearPlayHistory() {
        store.clearPlayHistory()
        emitChange("play_history", null)
    }

    private suspend fun emitChange(key: String?, value: String?) {
        _changes.emit(
            PreferenceChange(
                key = key,
                value = value,
                preferences = store.getAllPreferences(),
            ),
        )
    }

    companion object {
        @Volatile
        private var instance: PreferencesService? = null

        fun getInstance(context: Context): PreferencesService =
            instance ?: synchronized(this) {
                instance ?: PreferencesService(context.applicationContext).also {
                    instance = it
                }
            }
    }
}
