package github.realtvop.aonsoku

import android.content.Intent
import android.content.pm.ActivityInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowCompat
import github.realtvop.aonsoku.plugins.audio.PlaybackService
import github.realtvop.aonsoku.plugins.debug.DebugActivity
import github.realtvop.aonsoku.ui.AonsokuApp
import github.realtvop.aonsoku.ui.player.PlayerSheetLink

class MainActivity : ComponentActivity(), SensorEventListener {
    private var sensorManager: SensorManager? = null
    private var shakeSensor: Sensor? = null
    private val shakeDetector = DebugShakeDetector(::openDebugPage)
    private val playerLink = PlayerSheetLink()
    private var audioManager: AudioManager? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        if (!resources.getBoolean(R.bool.is_tablet)) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // The floating navigation bar supplies its own contrast.
            window.isNavigationBarContrastEnforced = false
        }

        val graph = (application as AonsokuApplication).graph
        setContent {
            AonsokuApp(graph, playerLink) { dark ->
                // Light icons on a dark backdrop, and the other way around.
                val view = LocalView.current
                SideEffect {
                    WindowCompat.getInsetsController(window, view).apply {
                        isAppearanceLightStatusBars = !dark
                        isAppearanceLightNavigationBars = !dark
                    }
                }
            }
        }

        sensorManager = getSystemService(SENSOR_SERVICE) as? SensorManager
        shakeSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
            ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        audioManager = getSystemService(AUDIO_SERVICE) as? AudioManager
        // A recreated activity has handled its intent already.
        if (savedInstanceState == null) openPlayerIfAsked(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        openPlayerIfAsked(intent)
    }

    /** The playback notification and the system's media controls open the player. */
    private fun openPlayerIfAsked(intent: Intent?) {
        if (intent?.getBooleanExtra(PlaybackService.EXTRA_OPEN_PLAYER, false) != true) return
        intent.removeExtra(PlaybackService.EXTRA_OPEN_PLAYER)
        playerLink.requestOpen()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val direction = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> AudioManager.ADJUST_RAISE
            KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER
            else -> return super.dispatchKeyEvent(event)
        }
        val audio = audioManager
        if (!playerLink.showsVolume || audio == null) return super.dispatchKeyEvent(event)
        // Without FLAG_SHOW_UI: the player's own volume bar shows the change.
        if (event.action == KeyEvent.ACTION_DOWN) {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, 0)
        }
        return true
    }

    override fun onResume() {
        super.onResume()
        shakeSensor?.let { sensor ->
            sensorManager?.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    override fun onPause() {
        super.onPause()
        sensorManager?.unregisterListener(this)
        shakeDetector.reset()
    }

    override fun onSensorChanged(event: SensorEvent) {
        shakeDetector.handleSensorData(event.sensor.type, event.values, System.currentTimeMillis())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    /** Shaking the device opens the native playback debug page. */
    private fun openDebugPage() {
        runOnUiThread {
            if (isFinishing || isDestroyed) return@runOnUiThread
            try {
                startActivity(Intent(this, DebugActivity::class.java))
            } catch (error: Throwable) {
                Log.e("MainActivity", "Failed to open debug page", error)
            }
        }
    }
}
