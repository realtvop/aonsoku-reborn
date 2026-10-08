package github.realtvop.aonsoku

import android.content.Intent
import android.content.pm.ActivityInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import github.realtvop.aonsoku.plugins.debug.DebugActivity
import github.realtvop.aonsoku.ui.AonsokuApp

class MainActivity : ComponentActivity(), SensorEventListener {
    private var sensorManager: SensorManager? = null
    private var shakeSensor: Sensor? = null
    private var debugShakeDetector: DebugShakeDetector? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        if (!resources.getBoolean(R.bool.is_tablet)) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        sensorManager = getSystemService(SENSOR_SERVICE) as? SensorManager
        if (sensorManager != null) {
            val linearAccel = sensorManager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
            shakeSensor = linearAccel ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        }
        debugShakeDetector = DebugShakeDetector { openDebugPage() }

        setContent {
            AonsokuApp()
        }
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
        debugShakeDetector?.reset()
    }

    override fun onSensorChanged(event: SensorEvent) {
        debugShakeDetector?.handleSensorData(event.sensor.type, event.values, System.currentTimeMillis())
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun openDebugPage() {
        runOnUiThread {
            if (isFinishing || isDestroyed) return@runOnUiThread
            try {
                val intent = Intent(this@MainActivity, DebugActivity::class.java)
                startActivity(intent)
            } catch (t: Throwable) {
                android.util.Log.e("MainActivity", "Failed to open debug page", t)
            }
        }
    }
}
