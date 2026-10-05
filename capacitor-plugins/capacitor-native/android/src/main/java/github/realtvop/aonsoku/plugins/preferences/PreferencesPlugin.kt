package github.realtvop.aonsoku.plugins.preferences

import android.os.Handler
import android.os.Looper
import com.getcapacitor.JSObject
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import github.realtvop.aonsoku.plugins.debug.NativeLogger

@CapacitorPlugin(name = "AonsokuNativePreferences")
class PreferencesPlugin : Plugin() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val preferencesService: PreferencesService by lazy {
        PreferencesService.getInstance(context)
    }
    private var changeJob: Job? = null

    override fun load() {
        super.load()
        changeJob = pluginScope.launch {
            preferencesService.changes.collect { change ->
                val payload = JSObject().apply {
                    change.key?.let { put("key", it) }
                    change.value?.let { put("value", it) }
                    put("preferences", JSObject().apply {
                        for ((key, value) in change.preferences) {
                            put(key, value)
                        }
                    })
                }
                mainHandler.post {
                    notifyListeners("preferencesChanged", payload)
                }
            }
        }
    }

    @PluginMethod
    fun getAllPreferences(call: PluginCall) {
        pluginScope.launch {
            try {
                val preferences = JSObject()
                for ((key, value) in preferencesService.getAllPreferences()) {
                    preferences.put(key, value)
                }
                resolve(
                    call,
                    JSObject().apply { put("preferences", preferences) },
                )
            } catch (e: Exception) {
                NativeLogger.error("Failed to read preferences: ${e.localizedMessage}", "preferences-plugin")
                reject(call, "Failed to read preferences: ${e.localizedMessage}")
            }
        }
    }

    @PluginMethod
    fun setPreferences(call: PluginCall) {
        val preferences = call.getObject("preferences")
        if (preferences == null) {
            reject(call, "Missing preferences object")
            return
        }

        val pairs = mutableMapOf<String, String>()
        val keys = preferences.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            pairs[key] = valueToString(preferences.opt(key))
        }

        pluginScope.launch {
            try {
                preferencesService.setPreferences(pairs)
                resolve(call)
            } catch (e: Exception) {
                NativeLogger.error("Failed to write preferences: ${e.localizedMessage}", "preferences-plugin")
                reject(call, "Failed to write preferences")
            }
        }
    }

    @PluginMethod
    fun setPreference(call: PluginCall) {
        val key = call.getString("key")
        if (key.isNullOrBlank()) {
            reject(call, "Missing key")
            return
        }

        val value = valueToString(call.data.opt("value"))
        pluginScope.launch {
            try {
                preferencesService.setPreference(key, value)
                resolve(call)
            } catch (e: Exception) {
                NativeLogger.error("Failed to write preference: ${e.localizedMessage}", "preferences-plugin")
                reject(call, "Failed to write preference")
            }
        }
    }

    @PluginMethod
    fun deletePreference(call: PluginCall) {
        val key = call.getString("key")
        if (key.isNullOrBlank()) {
            reject(call, "Missing key")
            return
        }

        pluginScope.launch {
            try {
                preferencesService.deletePreference(key)
                resolve(call)
            } catch (e: Exception) {
                NativeLogger.error("Failed to delete preference: ${e.localizedMessage}", "preferences-plugin")
                reject(call, "Failed to delete preference")
            }
        }
    }

    @PluginMethod
    fun getQueueState(call: PluginCall) {
        pluginScope.launch {
            try {
                val state = preferencesService.getQueueState()
                resolve(
                    call,
                    JSObject().apply { put("state", state ?: JSONObject.NULL) },
                )
            } catch (e: Exception) {
                NativeLogger.error("Failed to read queue state: ${e.localizedMessage}", "preferences-plugin")
                reject(call, "Failed to read queue state")
            }
        }
    }

    @PluginMethod
    fun setQueueState(call: PluginCall) {
        val state = call.getString("state")
        if (state == null) {
            reject(call, "Missing state")
            return
        }

        pluginScope.launch {
            try {
                preferencesService.setQueueState(state)
                resolve(call)
            } catch (e: Exception) {
                NativeLogger.error("Failed to write queue state: ${e.localizedMessage}", "preferences-plugin")
                reject(call, "Failed to write queue state")
            }
        }
    }

    @PluginMethod
    fun getPlayHistory(call: PluginCall) {
        val limit = call.getInt("limit") ?: DEFAULT_HISTORY_LIMIT
        pluginScope.launch {
            try {
                resolve(
                    call,
                    JSObject().apply {
                        put("history", JSONArray(preferencesService.getPlayHistory(limit)))
                    },
                )
            } catch (_: Exception) {
                reject(call, "Failed to read play history")
            }
        }
    }

    @PluginMethod
    fun addToPlayHistory(call: PluginCall) {
        val song = call.getString("song")
        if (song.isNullOrBlank()) {
            reject(call, "Missing song")
            return
        }

        val maxSize = call.getInt("maxSize") ?: DEFAULT_HISTORY_LIMIT
        pluginScope.launch {
            try {
                preferencesService.addToPlayHistory(song, maxSize)
                resolve(call)
            } catch (_: Exception) {
                reject(call, "Failed to write play history")
            }
        }
    }

    @PluginMethod
    fun clearPlayHistory(call: PluginCall) {
        pluginScope.launch {
            try {
                preferencesService.clearPlayHistory()
                resolve(call)
            } catch (_: Exception) {
                reject(call, "Failed to clear play history")
            }
        }
    }

    override fun handleOnDestroy() {
        changeJob?.cancel()
        pluginScope.cancel()
        super.handleOnDestroy()
    }

    private fun valueToString(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is String -> value
        is JSONObject -> value.toString()
        is JSONArray -> value.toString()
        else -> value.toString()
    }

    private fun resolve(call: PluginCall) {
        mainHandler.post { call.resolve() }
    }

    private fun resolve(call: PluginCall, data: JSObject) {
        mainHandler.post { call.resolve(data) }
    }

    private fun reject(call: PluginCall, message: String) {
        mainHandler.post { call.reject(message) }
    }

    companion object {
        private const val DEFAULT_HISTORY_LIMIT = 100
    }
}
