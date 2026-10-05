package github.realtvop.aonsoku.plugins

import android.content.Context
import github.realtvop.aonsoku.plugins.audio.AudioService
import github.realtvop.aonsoku.plugins.bridge.AuthenticationService
import github.realtvop.aonsoku.plugins.coordination.CoordinationService
import github.realtvop.aonsoku.plugins.data.LibraryService
import github.realtvop.aonsoku.plugins.preferences.PreferencesService
import java.util.concurrent.atomic.AtomicReference

/**
 * Application-scoped graph for native services shared by UI, plugins, and
 * Android foreground services. Registrations are replace-safe so service
 * recreation cannot leave a stale consumer in the graph.
 */
class AppServices private constructor(context: Context) {
    val authentication: AuthenticationService =
        AuthenticationService.getInstance(context.applicationContext)
    val preferences: PreferencesService =
        PreferencesService.getInstance(context.applicationContext)
    val library: LibraryService = LibraryService.getInstance(context.applicationContext)

    private val audio = AtomicReference<AudioService?>(null)
    private val coordination = AtomicReference<CoordinationService?>(null)

    fun audioService(): AudioService? = audio.get()

    fun coordinationService(): CoordinationService? = coordination.get()

    fun registerAudioService(service: AudioService) {
        audio.set(service)
    }

    fun unregisterAudioService(service: AudioService) {
        audio.compareAndSet(service, null)
    }

    fun registerCoordinationService(service: CoordinationService) {
        coordination.set(service)
    }

    fun unregisterCoordinationService(service: CoordinationService) {
        coordination.compareAndSet(service, null)
    }

    companion object {
        @Volatile
        private var instance: AppServices? = null

        fun getInstance(context: Context): AppServices = instance ?: synchronized(this) {
            instance ?: AppServices(context.applicationContext).also { instance = it }
        }

        fun current(): AppServices? = instance
    }
}
