package github.realtvop.aonsoku

import android.content.Intent
import android.content.pm.ActivityInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.platform.LocalView
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.WindowCompat
import github.realtvop.aonsoku.plugins.debug.DebugActivity
import github.realtvop.aonsoku.ui.AonsokuApp

class MainActivity : ComponentActivity(), SensorEventListener {
    private var sensorManager: SensorManager? = null
    private var shakeSensor: Sensor? = null
    private val shakeDetector = DebugShakeDetector(::openDebugPage)

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
            AonsokuApp(graph) { dark ->
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
