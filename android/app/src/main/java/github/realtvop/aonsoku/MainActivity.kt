package github.realtvop.aonsoku

import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import github.realtvop.aonsoku.plugins.audio.PlaybackService
import github.realtvop.aonsoku.ui.AonsokuApp
import github.realtvop.aonsoku.ui.AonsokuViewModel

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AonsokuViewModel>()
    private var playbackBound = false

    private val playbackConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? PlaybackService.LocalBinder ?: return
            viewModel.attachAudioService(binder.getAudioService())
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            viewModel.detachAudioService()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        if (!resources.getBoolean(R.bool.is_tablet)) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }

        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        startAndBindPlaybackService()

        setContent {
            AonsokuApp(viewModel = viewModel)
        }
    }

    override fun onDestroy() {
        if (playbackBound) {
            unbindService(playbackConnection)
            playbackBound = false
        }
        super.onDestroy()
    }

    private fun startAndBindPlaybackService() {
        val intent = Intent(this, PlaybackService::class.java)
        ContextCompat.startForegroundService(this, intent)
        playbackBound = bindService(intent, playbackConnection, BIND_AUTO_CREATE)
    }
}
