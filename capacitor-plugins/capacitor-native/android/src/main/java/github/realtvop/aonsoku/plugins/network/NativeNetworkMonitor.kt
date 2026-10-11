package github.realtvop.aonsoku.plugins.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import github.realtvop.aonsoku.plugins.AppServices
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/** Process lifetime network and primary/fallback selection, shared by native UI/services. */
class NativeNetworkMonitor private constructor(private val context: Context) {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val services = AppServices.getInstance(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val probeMutex = Mutex()
    val online = MutableStateFlow(connected())
    val metered = MutableStateFlow(manager.isActiveNetworkMetered)
    private fun connected() = manager.getNetworkCapabilities(manager.activeNetwork)?.let { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) } == true
    init {
        manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { online.value = connected(); refresh() }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { metered.value = manager.isActiveNetworkMetered; val was = online.value; online.value = connected(); if (!was && online.value) refresh() }
            override fun onLost(network: Network) { online.value = connected() }
        })
    }
    fun refresh() = scope.launch {
        online.value = connected()
        if (!online.value) return@launch
        probeMutex.withLock {
            val credentials = services.authentication.getCredentials() ?: return@withLock
            val preferences = services.preferences.getAllPreferences()
            val data = runCatching { JSONObject(preferences["app_store"] ?: "{}").getJSONObject("state").getJSONObject("data") }.getOrDefault(JSONObject())
            val primary = data.optString("primaryUrl").takeIf(String::isNotBlank) ?: credentials.serverUrl
            val fallback = data.optString("fallbackUrl").takeIf(String::isNotBlank) ?: credentials.fallbackUrl
            val target = listOfNotNull(primary, fallback).distinct().firstOrNull { services.authentication.ping(it, credentials.username, credentials.password, credentials.authType).reachable } ?: return@withLock
            if (target != credentials.serverUrl) {
                services.authentication.storeCredentials(credentials.copy(serverUrl = target))
                services.library.refreshCredentials()
            }
            github.realtvop.aonsoku.plugins.coordination.CoordinationController.getInstance(context).resume()
        }
    }
    companion object {
        @Volatile private var instance: NativeNetworkMonitor? = null
        fun getInstance(context: Context): NativeNetworkMonitor = instance ?: synchronized(this) { instance ?: NativeNetworkMonitor(context.applicationContext).also { instance = it } }
    }
}
