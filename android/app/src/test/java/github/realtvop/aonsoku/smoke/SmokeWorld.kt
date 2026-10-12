package github.realtvop.aonsoku.smoke

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.room.RoomDatabase
import androidx.test.core.app.ApplicationProvider
import coil3.SingletonImageLoader
import coil3.annotation.DelicateCoilApi
import coil3.imageDecoderEnabled
import coil3.request.crossfade
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.data.image.artworkImageLoader
import github.realtvop.aonsoku.plugins.audio.PlaybackService
import github.realtvop.aonsoku.session.LoginResult
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.shadows.ShadowNetworkCapabilities
import java.time.Duration

/**
 * Everything a smoke test needs around the UI: a fake Subsonic server, a real
 * [AppGraph] on top of the real native services (Room, DataStore, credential
 * store), and helpers to wait for asynchronous work.
 *
 * Robolectric hands every test a fresh application and data directory but
 * keeps static state, so the process-wide service singletons are reset around
 * each test.
 */
class SmokeWorld : TestWatcher() {
    val server = FakeSubsonicServer()

    lateinit var graph: AppGraph
        private set

    private var playback: ServiceController<PlaybackService>? = null

    @OptIn(DelicateCoilApi::class)
    override fun starting(description: Description) {
        System.setProperty("java.awt.headless", "true")
        FakeAndroidKeyStore.install()
        resetSingletons()
        server.start()

        val application = ApplicationProvider.getApplicationContext<Application>()
        // The Compose rule hosts the UI in a plain activity.
        shadowOf(application.packageManager).addActivityIfNotPresent(
            ComponentName(application.packageName, ComponentActivity::class.java.name),
        )
        metered(false)
        // Nothing a test does may reach the internet, LRCLIB included.
        graph = AppGraph(application, lrcLibUrl = server.lrcLibUrl).also { it.initialize() }
        startPlaybackService(application)
        SingletonImageLoader.setUnsafe { context ->
            // Robolectric decodes files with BitmapFactory but not with ImageDecoder.
            // A fade runs on wall-clock time, so a screenshot would catch it half-way.
            artworkImageLoader(context, graph.artwork)
                .imageDecoderEnabled(false)
                .crossfade(false)
                .build()
        }
    }

    /**
     * Runs the real playback service in this process and hands its binder to
     * whoever binds it, as the system would.
     */
    private fun startPlaybackService(application: Application) {
        val controller = Robolectric.buildService(PlaybackService::class.java).create()
        playback = controller
        shadowOf(application).setComponentNameAndServiceForBindService(
            ComponentName(application, PlaybackService::class.java),
            controller.get().onBind(Intent(application, PlaybackService::class.java)),
        )
    }

    @OptIn(DelicateCoilApi::class)
    override fun finished(description: Description) {
        runCatching { graph.player.shutdown() }
        runCatching { playback?.destroy() }
        runCatching { graph.scope.cancel() }
        server.shutdown()
        SingletonImageLoader.reset()
        resetSingletons()
    }

    /**
     * Says what kind of connection the device is on; the app reads it when a
     * session starts. Tests run on an unmetered one, the case in which nothing
     * is held back, unless they ask for the other.
     */
    fun metered(metered: Boolean) {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val connectivity = application.getSystemService(ConnectivityManager::class.java)
        val capabilities = ShadowNetworkCapabilities.newInstance()
        shadowOf(capabilities).apply {
            addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            if (!metered) addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        }
        shadowOf(connectivity).setNetworkCapabilities(connectivity.activeNetwork, capabilities)
    }

    /** Signs in to the fake server and starts the session like the login screen does. */
    fun signIn() {
        val result = await { graph.session.login(server.url, USERNAME, PASSWORD) }
        check(result == LoginResult.Success) { "Sign-in failed: $result" }
        graph.startSession()
    }

    /** Runs [block] on the app scope and waits for it while keeping the main thread alive. */
    fun <T> await(timeoutMillis: Long = TIMEOUT_MS, block: suspend () -> T): T {
        val deferred = graph.scope.async { block() }
        waitUntil("the operation to finish", timeoutMillis) { deferred.isCompleted }
        return deferred.getCompleted()
    }

    /**
     * Waits for [condition], running main-thread work (including delayed
     * tasks) while background threads make progress.
     */
    fun waitUntil(what: String, timeoutMillis: Long = TIMEOUT_MS, condition: () -> Boolean) {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000
        while (true) {
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(STEP_MS))
            if (condition()) return
            if (System.nanoTime() > deadline) throw AssertionError("Timed out waiting for $what")
            Thread.sleep(STEP_MS)
        }
    }

    /** State worth knowing when a wait times out. */
    fun describe(): String {
        val player = graph.player.state.value
        return "online=${graph.network.isOnline.value} requests=${server.requests.distinct()} " +
            "player=${player.current?.title}/playing=${player.isPlaying}/loading=${player.isLoading}"
    }

    private fun resetSingletons() {
        SINGLETONS.forEach { (className, fieldName) ->
            val field = Class.forName(className).getDeclaredField(fieldName).apply {
                isAccessible = true
            }
            (field.get(null) as? RoomDatabase)?.let { runCatching { it.close() } }
            field.set(null, null)
        }
    }

    companion object {
        const val USERNAME = "tester"
        const val PASSWORD = "not-a-real-password"
        const val TIMEOUT_MS = 20_000L
        private const val STEP_MS = 10L

        private const val CORE = "github.realtvop.aonsoku.plugins"

        /** Static holders of the `:core` services, as (class, field). */
        private val SINGLETONS = listOf(
            "$CORE.AppServices" to "instance",
            "$CORE.bridge.AuthenticationService" to "instance",
            "$CORE.preferences.PreferencesService" to "instance",
            "$CORE.preferences.NativePreferencesStore" to "sharedDataStore",
            "$CORE.data.LibraryService" to "instance",
            "$CORE.audio.AudioCacheService" to "instance",
            "$CORE.data.db.AonsokuDatabase" to "INSTANCE",
            "$CORE.coordination.CoordinationRuntime" to "instance",
        )
    }
}
