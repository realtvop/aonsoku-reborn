package github.realtvop.aonsoku.plugins.audio

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlaybackServiceManifestTest {
    @Test
    fun testPlaybackServiceIsResolvable() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = Intent(appContext, PlaybackService::class.java)
        val resolveInfo = appContext.packageManager.resolveService(intent, 0)
        assertNotNull("PlaybackService should be registered and resolvable in AndroidManifest", resolveInfo)
    }

    @Test
    fun testForegroundMediaPlaybackPermission() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val result = appContext.packageManager.checkPermission(
                Manifest.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK,
                appContext.packageName
            )
            assertEquals(
                "FOREGROUND_SERVICE_MEDIA_PLAYBACK permission should be declared",
                PackageManager.PERMISSION_GRANTED,
                result
            )
        }
    }

    @Test
    fun testMediaSessionServiceIntentFilter() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = Intent("androidx.media3.session.MediaSessionService")
        val resolveInfo = appContext.packageManager.resolveService(intent, 0)
        assertNotNull("PlaybackService should have MediaSessionService intent-filter", resolveInfo)
    }

    @Test
    fun testAppUsesInternetPermission() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext
        val result = appContext.packageManager.checkPermission(
            Manifest.permission.INTERNET,
            appContext.packageName
        )
        assertEquals("INTERNET permission should be granted", PackageManager.PERMISSION_GRANTED, result)
    }
}
