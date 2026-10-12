package github.realtvop.aonsoku.plugins.audio

import android.content.Context
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.mockito.Mockito

class NativeDownloadManagerTest {

    @Test
    fun testDownloadManagerInitialization() {
        val context = Mockito.mock(Context::class.java)
        val downloadManager = NativeDownloadManager(context)
        assertNotNull(downloadManager)
    }

    @Test
    fun testDownloadManagerListenerHandling() {
        val context = Mockito.mock(Context::class.java)
        val downloadManager = NativeDownloadManager(context)
        val listener = object : NativeDownloadManager.Listener {
            override fun onDownloadProgress(songId: String, loaded: Long, total: Long) {}
            override fun onDownloadCompleted(songId: String, fileUri: String, contentType: String, sizeBytes: Long) {}
            override fun onDownloadFailed(songId: String, errorMessage: String) {}
        }
        
        // Ensure adding and removing listeners works without throwing exceptions
        downloadManager.addListener(listener)
        downloadManager.removeListener(listener)
    }

    @Test
    fun testCancelInactiveDownload() {
        val context = Mockito.mock(Context::class.java)
        val downloadManager = NativeDownloadManager(context)
        
        // Canceling a non-existent download should fail gracefully / do nothing
        downloadManager.cancel("non-existent-song")
        downloadManager.cancelAll()
    }
}
