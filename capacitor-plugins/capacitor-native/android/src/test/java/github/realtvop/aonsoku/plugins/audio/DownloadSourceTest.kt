package github.realtvop.aonsoku.plugins.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadSourceTest {
    @Test fun playbackCannotDemoteProtectedDownloads() {
        assertEquals("explicit", NativeDownloadManager.promotedSource("explicit", "lru"))
        assertEquals("explicit", NativeDownloadManager.promotedSource("explicit", "smart"))
        assertEquals("smart", NativeDownloadManager.promotedSource("smart", "lru"))
    }
    @Test fun manualDownloadPromotesExistingBackgroundAudio() {
        assertEquals("explicit", NativeDownloadManager.promotedSource("lru", "explicit"))
        assertEquals("smart", NativeDownloadManager.promotedSource("lru", "smart"))
        assertEquals("explicit", NativeDownloadManager.promotedSource(null, "explicit"))
    }
}
