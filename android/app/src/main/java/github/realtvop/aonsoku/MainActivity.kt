package github.realtvop.aonsoku

import android.Manifest
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.media.AudioManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import github.realtvop.aonsoku.ui.AonsokuApp
import github.realtvop.aonsoku.ui.AonsokuViewModel

/** The production Android entry point contains only native Compose UI. */
class MainActivity : ComponentActivity(), android.hardware.SensorEventListener {
    private val sensors by lazy { getSystemService(SENSOR_SERVICE) as android.hardware.SensorManager }
    private val shake = DebugShakeDetector { startActivity(android.content.Intent(this, github.realtvop.aonsoku.plugins.debug.DebugActivity::class.java)) }
    override fun onSensorChanged(event: android.hardware.SensorEvent) { shake.handleSensorData(event.sensor.type, event.values, event.timestamp / 1000000) }
    override fun onAccuracyChanged(sensor: android.hardware.Sensor?, accuracy: Int) {}
    override fun onPause() { sensors.unregisterListener(this); shake.reset(); super.onPause() }
    private val model: AonsokuViewModel by viewModels()
    private val notifications = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.AppTheme_NoActionBar)
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        volumeControlStream = AudioManager.STREAM_MUSIC
        setContent { AonsokuApp(model) }
        if (Build.VERSION.SDK_INT >= 33) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    override fun onResume() { super.onResume(); model.coordinator.resume(); model.network.refresh();
        val sensor = sensors.getDefaultSensor(android.hardware.Sensor.TYPE_LINEAR_ACCELERATION) ?: sensors.getDefaultSensor(android.hardware.Sensor.TYPE_ACCELEROMETER)
        sensor?.let { sensors.registerListener(this, it, android.hardware.SensorManager.SENSOR_DELAY_GAME) }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (model.booleanPreference("native.hideVolumeHud", false) &&
            event.keyCode in listOf(KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN)) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                (getSystemService(AUDIO_SERVICE) as AudioManager).adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                    0,
                )
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }
}
