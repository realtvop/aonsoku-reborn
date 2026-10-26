package github.realtvop.aonsoku.data

import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** The last successful Home query results, including their random ordering. */
@Serializable
data class HomeSnapshot(
    val accountKey: String,
    val carousel: List<Album>? = null,
    val sections: Map<String, List<Album>> = emptyMap(),
    val carouselUpdatedAt: Long? = null,
    val exploreUpdatedAt: Long? = null,
)

class HomeCache(private val preferences: PreferencesService) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun read(accountKey: String): HomeSnapshot? {
        val raw = preferences.getAllPreferences()[KEY] ?: return null
        return runCatching { json.decodeFromString(HomeSnapshot.serializer(), raw) }
            .getOrNull()?.takeIf { it.accountKey == accountKey }
    }

    suspend fun write(snapshot: HomeSnapshot) {
        preferences.setPreference(KEY, json.encodeToString(HomeSnapshot.serializer(), snapshot))
    }

    suspend fun clear() = preferences.deletePreference(KEY)

    private companion object {
        const val KEY = "home.snapshot.v1"
    }
}
