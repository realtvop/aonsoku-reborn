package github.realtvop.aonsoku.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Tracks whether the configured server is reachable ("online") and whether
 * the current connection is metered. Online means an authenticated ping to a
 * configured URL succeeded, not merely that the device has connectivity:
 * a home server can be unreachable while the phone is on mobile data.
 */
class NetworkMonitor(
    context: Context,
    private val scope: CoroutineScope,
    /** Authenticated reachability probe; true when any configured URL answers. */
    private val probe: suspend () -> Boolean,
) {
    private val connectivity =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager
    private val _isOnline = MutableStateFlow(true)
    private val _isMetered = MutableStateFlow(false)
    private var checkJob: Job? = null
    private var registered = false

    val isOnline: StateFlow<Boolean> = _isOnline.asStateFlow()
    val isMetered: StateFlow<Boolean> = _isMetered.asStateFlow()

    val online: Boolean get() = _isOnline.value

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            scheduleCheck(RECONNECT_CHECK_DELAY_MS)
        }

        override fun onLost(network: Network) {
            if (connectivity?.activeNetwork == null) {
                checkJob?.cancel()
                _isOnline.value = false
            } else {
                scheduleCheck(RECONNECT_CHECK_DELAY_MS)
            }
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            _isMetered.value = isMetered(capabilities)
        }
    }

    fun start() {
        if (registered) return
        registered = true
        runCatching { connectivity?.registerDefaultNetworkCallback(callback) }
        connectivity?.let { manager ->
            manager.getNetworkCapabilities(manager.activeNetwork)?.let {
                _isMetered.value = isMetered(it)
            }
        }
        scheduleCheck(0)
    }

    /** Re-probe when the app returns to the foreground while offline. */
    fun onForeground() {
        if (!_isOnline.value) scheduleCheck(0)
    }

    /** Called when a request failed at the transport level. */
    fun markServerUnreachable() {
        if (!_isOnline.value) return
        _isOnline.value = false
        scheduleCheck(UNREACHABLE_RECHECK_DELAY_MS)
    }

    fun scheduleCheck(delayMillis: Long) {
        checkJob?.cancel()
        checkJob = scope.launch {
            if (delayMillis > 0) delay(delayMillis)
            _isOnline.value = runCatching { probe() }.getOrDefault(false)
        }
    }

    /** Runs the probe now and returns the fresh result. */
    suspend fun checkNow(): Boolean {
        checkJob?.cancel()
        val reachable = runCatching { probe() }.getOrDefault(false)
        _isOnline.value = reachable
        return reachable
    }

    private fun isMetered(capabilities: NetworkCapabilities): Boolean =
        !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)

    private companion object {
        const val RECONNECT_CHECK_DELAY_MS = 200L
        const val UNREACHABLE_RECHECK_DELAY_MS = 5_000L
    }
}
