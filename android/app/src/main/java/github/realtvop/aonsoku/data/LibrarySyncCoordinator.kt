package github.realtvop.aonsoku.data

import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.plugins.data.LibrarySyncState
import github.realtvop.aonsoku.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Decides when the offline library is synchronized. Mirrors the web
 * `MetadataSyncObserver`: a sync when a session starts, then an incremental
 * sync whenever the app returns to the foreground (at most every five
 * minutes). Automatic runs are skipped while offline or on a metered
 * connection; a manual sync is always allowed.
 */
class LibrarySyncCoordinator(
    private val library: LibraryService,
    private val network: NetworkMonitor,
    private val settings: SettingsRepository,
    private val scope: CoroutineScope,
) {
    private var sessionJob: Job? = null
    private var startedForSession = false
    private var lastAutomaticSyncAt = 0L

    val state: StateFlow<LibrarySyncState> = library.syncState

    /** Call when a session becomes active (app start while signed in, or login). */
    fun onSessionStarted() {
        sessionJob?.cancel()
        startedForSession = false
        sessionJob = scope.launch {
            launch { trackCompletion() }
            // Wait for the first reachability result before deciding.
            network.isOnline.first { it }
            startInitialSync()
        }
    }

    fun onSessionEnded() {
        sessionJob?.cancel()
        sessionJob = null
        startedForSession = false
        library.cancelSync()
    }

    /** Incremental sync when the app comes back to the foreground. */
    fun onForeground() {
        if (!startedForSession || !canSyncAutomatically()) return
        val now = System.currentTimeMillis()
        if (now - lastAutomaticSyncAt < FOCUS_THROTTLE_MS) return
        lastAutomaticSyncAt = now
        library.syncIncremental()
    }

    /** User-initiated refresh; allowed on metered connections. */
    fun syncNow(): Boolean {
        if (!network.online || library.syncState.value.isSyncing) return false
        lastAutomaticSyncAt = System.currentTimeMillis()
        library.syncIncremental()
        return true
    }

    fun cancel() = library.cancelSync()

    private suspend fun startInitialSync() {
        if (startedForSession) return
        val initialization = library.initialize()
        if (network.isMetered.value && !initialization.needsMigration) {
            startedForSession = true
            return
        }
        startedForSession = true
        lastAutomaticSyncAt = System.currentTimeMillis()
        // A library that never completed a full sync is populated now; an
        // existing one is refreshed in full to catch server-side deletions.
        library.syncAll()
    }

    private fun canSyncAutomatically(): Boolean =
        network.online && !network.isMetered.value && !library.syncState.value.isSyncing

    private suspend fun trackCompletion() {
        library.syncState.collect { state ->
            if (state.phase == "done") {
                settings.update {
                    it.copy(cache = it.cache.copy(lastSyncedAt = System.currentTimeMillis()))
                }
            }
        }
    }

    private companion object {
        const val FOCUS_THROTTLE_MS = 5 * 60 * 1000L
    }
}
