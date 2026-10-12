package github.realtvop.aonsoku

import android.app.Application
import androidx.compose.runtime.staticCompositionLocalOf
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.session.SessionManager
import github.realtvop.aonsoku.settings.SettingsRepository
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking

/**
 * Application-scoped object graph of the native app. It sits on top of the
 * long-lived native services in `:core` and outlives every Activity.
 */
class AppGraph(val application: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val services: AppServices = AppServices.getInstance(application)
    val settings = SettingsRepository(services.preferences, scope)
    val session = SessionManager(services.authentication, settings)
    val toaster = Toaster()

    /**
     * Loads what the first frame depends on (theme, language, session). Both
     * reads are local and short, and the splash screen covers them.
     */
    fun initialize() {
        runBlocking(Dispatchers.IO) {
            settings.load()
            session.restore()
        }
    }

    /** Ends the session and drops everything tied to the signed-in account. */
    suspend fun signOut() {
        session.logout()
    }
}

val LocalAppGraph = staticCompositionLocalOf<AppGraph> {
    error("AppGraph is not provided")
}
