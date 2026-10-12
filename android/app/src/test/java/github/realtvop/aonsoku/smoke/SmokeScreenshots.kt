package github.realtvop.aonsoku.smoke

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.filterToOne
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import java.io.File

/**
 * Saves what a smoke test sees as PNG files, to look at the UI without a
 * device. It only does so when the run asks for it:
 *
 *     ./gradlew :app:testDebugUnitTest --tests '*AppSmokeTest*' \
 *         -PsmokeScreenshots=<directory> [-PsmokeTheme=dark]
 */
class SmokeScreenshots(private val compose: AndroidComposeTestRule<*, out ComponentActivity>) {
    private val directory: String? = System.getProperty(DIRECTORY_PROPERTY)

    val enabled: Boolean get() = directory != null

    /** Whether the run asks for the dark theme. */
    val dark: Boolean get() = System.getProperty(THEME_PROPERTY) == "dark"

    fun save(name: String) {
        val directory = directory ?: return
        val inActivity = SemanticsMatcher("is in the activity window") { node ->
            (node.root as ViewRootForTest).view.rootView === compose.activity.window.decorView
        }
        val page = compose.onAllNodes(isRoot()).filterToOne(inActivity).captureToImage()
        val image = page.asAndroidBitmap().copy(Bitmap.Config.ARGB_8888, true)
        // Sheets and dialogs are windows of their own, drawn over the activity.
        val canvas = Canvas(image)
        val dialogs = compose.onAllNodes(isDialog())
        repeat(dialogs.fetchSemanticsNodes().size) { index ->
            val bounds = dialogs[index].fetchSemanticsNode().boundsInWindow
            val dialog = dialogs[index].captureToImage().asAndroidBitmap()
            canvas.drawBitmap(dialog, bounds.left, bounds.top, null)
        }
        val file = File(directory, "$name.png").apply { parentFile?.mkdirs() }
        file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private companion object {
        const val DIRECTORY_PROPERTY = "aonsoku.smoke.screenshots"
        const val THEME_PROPERTY = "aonsoku.smoke.theme"
    }
}
