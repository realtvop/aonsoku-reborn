package github.realtvop.aonsoku.plugins.preferences

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStoreFile
import kotlinx.coroutines.flow.first

class NativePreferencesStore(context: Context) {
    private val dataStore = getSharedDataStore(context)

    suspend fun getAllPreferences(): Map<String, String> {
        val snapshot = dataStore.data.first()
        return snapshot.asMap()
            .mapNotNull { (key, value) ->
                if (!key.name.startsWith(PREFERENCE_PREFIX)) return@mapNotNull null
                val stringValue = value as? String ?: return@mapNotNull null
                key.name.removePrefix(PREFERENCE_PREFIX) to stringValue
            }
            .toMap()
    }

    suspend fun setPreferences(preferences: Map<String, String>) {
        dataStore.edit { mutablePreferences ->
            for ((key, value) in preferences) {
                mutablePreferences[preferenceKey(key)] = value
            }
        }
    }

    suspend fun setPreference(key: String, value: String) {
        dataStore.edit { mutablePreferences ->
            mutablePreferences[preferenceKey(key)] = value
        }
    }

    suspend fun deletePreference(key: String) {
        dataStore.edit { mutablePreferences ->
            mutablePreferences.remove(preferenceKey(key))
        }
    }

    suspend fun getQueueState(): String? = dataStore.data.first()[QUEUE_STATE_KEY]

    suspend fun setQueueState(state: String) {
        dataStore.edit { mutablePreferences ->
            mutablePreferences[QUEUE_STATE_KEY] = state
        }
    }

    suspend fun getPlayHistory(limit: Int): List<String> {
        val history = PlayHistoryCodec.decode(dataStore.data.first()[PLAY_HISTORY_KEY])
        return history.take(limit.coerceAtLeast(0))
    }

    suspend fun addToPlayHistory(song: String, maxSize: Int) {
        dataStore.edit { mutablePreferences ->
            mutablePreferences[PLAY_HISTORY_KEY] = PlayHistoryCodec.add(
                raw = mutablePreferences[PLAY_HISTORY_KEY],
                song = song,
                maxSize = maxSize,
            )
        }
    }

    suspend fun clearPlayHistory() {
        dataStore.edit { mutablePreferences ->
            mutablePreferences.remove(PLAY_HISTORY_KEY)
        }
    }

    private fun preferenceKey(key: String): Preferences.Key<String> =
        stringPreferencesKey(PREFERENCE_PREFIX + key)

    companion object {
        private const val DATASTORE_NAME = "aonsoku_native_preferences"
        private const val PREFERENCE_PREFIX = "pref."
        private val QUEUE_STATE_KEY = stringPreferencesKey("queue_state")
        private val PLAY_HISTORY_KEY = stringPreferencesKey("play_history")

        private var sharedDataStore: DataStore<Preferences>? = null
        private val lock = Any()

        private fun getSharedDataStore(context: Context): DataStore<Preferences> {
            return synchronized(lock) {
                var instance = sharedDataStore
                if (instance == null) {
                    instance = PreferenceDataStoreFactory.create(
                        produceFile = {
                            context.applicationContext.preferencesDataStoreFile(DATASTORE_NAME)
                        }
                    )
                    sharedDataStore = instance
                }
                instance
            }
        }
    }
}
