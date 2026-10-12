package github.realtvop.aonsoku

import android.app.Application
import androidx.compose.runtime.staticCompositionLocalOf
import github.realtvop.aonsoku.actions.LibraryActions
import github.realtvop.aonsoku.data.LibraryChange
import github.realtvop.aonsoku.data.LibraryRepository
import github.realtvop.aonsoku.data.LibrarySyncCoordinator
import github.realtvop.aonsoku.data.NetworkMonitor
import github.realtvop.aonsoku.data.api.SubsonicApi
import github.realtvop.aonsoku.data.image.ArtworkStore
import github.realtvop.aonsoku.data.lyrics.LyricsRepository
import github.realtvop.aonsoku.data.lyrics.LyricsSources
import github.realtvop.aonsoku.data.lyrics.LyricsStore
import github.realtvop.aonsoku.i18n.I18n
import github.realtvop.aonsoku.i18n.Translations
import github.realtvop.aonsoku.player.PlayerController
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.session.SessionManager
import github.realtvop.aonsoku.session.SessionState
import github.realtvop.aonsoku.settings.SettingsRepository
import github.realtvop.aonsoku.ui.components.Toaster
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Application-scoped object graph of the native app. It sits on top of the
 * long-lived native services in `:core` and outlives every Activity.
 */
class AppGraph(
    val application: Application,
    /** Where LRCLIB is asked for lyrics; tests point it at a server of their own. */
    lrcLibUrl: String = LyricsSources.LRCLIB_URL,
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val services: AppServices = AppServices.getInstance(application)
    val settings = SettingsRepository(services.preferences, scope)
    val session = SessionManager(services.authentication, settings)
    val toaster = Toaster()

    val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()
    val network = NetworkMonitor(application, scope) { session.isServerReachable() }
    val api = SubsonicApi(
        credentials = { session.credentials },
        client = httpClient,
        onUnreachable = network::markServerUnreachable,
    )
    val artwork = ArtworkStore(services.library, network, scope)
    val library = LibraryRepository(api, services.library, network)
    val lyrics = LyricsRepository(
        api = api,
        library = services.library,
        songs = library,
        settings = settings,
        network = network,
        store = LyricsStore(
            choices = File(application.filesDir, "lyrics"),
            cache = File(application.cacheDir, "lyrics"),
        ),
        sources = LyricsSources(
            client = httpClient,
            clientName = "Aonsoku v${BuildConfig.APP_VERSION} (${BuildConfig.REPOSITORY_URL})",
            lrcLibUrl = lrcLibUrl,
        ),
        serverType = { session.credentials?.serverType },
    )
    val sync = LibrarySyncCoordinator(
        library = services.library,
        network = network,
        settings = settings,
        scope = scope,
        onSynced = { library.notifyChanged(LibraryChange.Library) },
    )
    val player = PlayerController(
        context = application,
        scope = scope,
        settings = settings,
        library = library,
        preferences = services.preferences,
        toaster = toaster,
        strings = ::strings,
    )
    val actions = LibraryActions(
        scope = scope,
        library = library,
        player = player,
        settings = settings,
        toaster = toaster,
        strings = ::strings,
    )

    /** Strings for the current language, for code that runs outside composition. */
    fun strings(): Translations = I18n.load(application, settings.current.language)

    /**
     * Loads what the first frame depends on (theme, language, session). Both
     * reads are local and short, and the splash screen covers them.
     */
    fun initialize() {
        runBlocking(Dispatchers.IO) {
            settings.load()
            session.restore()
        }
        if (session.state.value is SessionState.SignedIn) startSession()
    }

    /** Starts everything that only runs while signed in. */
    fun startSession() {
        network.start()
        network.scheduleCheck(0)
        sync.onSessionStarted()
        player.connect()
    }

    /** The session moved to another address of the server: look at it afresh. */
    fun onServerChanged() {
        network.scheduleCheck(0)
        library.notifyChanged(LibraryChange.Library)
    }

    /** The app came back to the foreground. */
    fun onForeground() {
        if (session.state.value !is SessionState.SignedIn) return
        network.onForeground()
        sync.onForeground()
    }

    fun onBackground() {
        settings.flush()
    }

    /** Ends the session and drops everything tied to the signed-in account. */
    suspend fun signOut() {
        player.shutdown()
        sync.onSessionEnded()
        session.logout()
        services.library.clearLibraryData()
        lyrics.clearCache()
        settings.update {
            it.copy(pinnedHome = emptyList(), cache = it.cache.copy(lastSyncedAt = null))
        }
    }
}

val LocalAppGraph = staticCompositionLocalOf<AppGraph> {
    error("AppGraph is not provided")
}
