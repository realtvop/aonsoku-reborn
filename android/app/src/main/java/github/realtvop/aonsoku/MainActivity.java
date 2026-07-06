package github.realtvop.aonsoku;

import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import com.getcapacitor.BridgeActivity;
import github.realtvop.aonsoku.plugins.audio.AudioPlugin;
import github.realtvop.aonsoku.plugins.bridge.BridgePlugin;
import github.realtvop.aonsoku.plugins.coordination.AonsokuNativeCoordinationPlugin;
import github.realtvop.aonsoku.plugins.data.DataPlugin;
import github.realtvop.aonsoku.plugins.preferences.PreferencesPlugin;
import github.realtvop.aonsoku.plugins.debug.DebugActivity;
import android.view.View;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

public class MainActivity extends BridgeActivity implements SensorEventListener {
    private SensorManager sensorManager;
    private Sensor shakeSensor;
    private DebugShakeDetector debugShakeDetector;

    @Override
    public void onCreate(android.os.Bundle savedInstanceState) {
        if (!getResources().getBoolean(R.bool.is_tablet)) {
            setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);
        }
        com.google.android.material.color.DynamicColors.applyToActivitiesIfAvailable(this.getApplication());
        registerPlugin(AudioPlugin.class);
        registerPlugin(BridgePlugin.class);
        registerPlugin(AonsokuNativeCoordinationPlugin.class);
        registerPlugin(DataPlugin.class);
        registerPlugin(PreferencesPlugin.class);

        super.onCreate(savedInstanceState);

        getBridge().getWebView().post(() -> {
            android.webkit.WebView webView = getBridge().getWebView();
            if (webView != null) {
                webView.setOverScrollMode(android.view.View.OVER_SCROLL_NEVER);
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    webView.setRendererPriorityPolicy(
                        android.webkit.WebView.RENDERER_PRIORITY_BOUND,
                        false
                    );
                }
            }

            View parent = (View) getBridge().getWebView().getParent();
            ViewCompat.setOnApplyWindowInsetsListener(parent, (v, insets) -> {
                v.setPadding(0, 0, 0, 0);
                return insets;
            });
            getBridge().getWebView().requestApplyInsets();
        });
        sensorManager = (SensorManager) getSystemService(SENSOR_SERVICE);
        if (sensorManager != null) {
            Sensor linearAccel = sensorManager.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION);
            if (linearAccel != null) {
                shakeSensor = linearAccel;
            } else {
                shakeSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
            }
        }
        debugShakeDetector = new DebugShakeDetector(this::openDebugPage);
    }

    @Override
    public void onResume() {
        super.onResume();
        if (sensorManager != null && shakeSensor != null) {
            sensorManager.registerListener(this, shakeSensor, SensorManager.SENSOR_DELAY_GAME);
        }
    }

    @Override
    public void onPause() {
        super.onPause();
        if (sensorManager != null) {
            sensorManager.unregisterListener(this);
        }
        if (debugShakeDetector != null) {
            debugShakeDetector.reset();
        }
    }

    @Override
    public void onSensorChanged(SensorEvent event) {
        if (debugShakeDetector != null) {
            debugShakeDetector.handleSensorData(event.sensor.getType(), event.values, System.currentTimeMillis());
        }
    }

    @Override
    public void onAccuracyChanged(Sensor sensor, int accuracy) {
    }

    private void openDebugPage() {
        android.util.Log.d("MainActivity", "Shake detected, opening debug page");
        runOnUiThread(() -> {
            if (isFinishing() || isDestroyed()) {
                return;
            }
            try {
                Intent intent = new Intent(MainActivity.this, DebugActivity.class);
                startActivity(intent);
            } catch (Throwable t) {
                android.util.Log.e("MainActivity", "Failed to open debug page", t);
            }
        });
    }

    @Override
    public boolean dispatchKeyEvent(android.view.KeyEvent event) {
        if (AudioPlugin.isVolumeHUDDisabled()) {
            int keyCode = event.getKeyCode();
            if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (event.getAction() == android.view.KeyEvent.ACTION_DOWN) {
                    android.media.AudioManager audioManager = (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
                    if (audioManager != null) {
                        int direction = (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) 
                            ? android.media.AudioManager.ADJUST_RAISE 
                            : android.media.AudioManager.ADJUST_LOWER;
                        audioManager.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, direction, 0);
                    }
                }
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }
}
