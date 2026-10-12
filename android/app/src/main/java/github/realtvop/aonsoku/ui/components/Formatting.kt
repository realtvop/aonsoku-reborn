package github.realtvop.aonsoku.ui.components

import android.graphics.Bitmap
import androidx.compose.ui.graphics.Color
import github.realtvop.aonsoku.i18n.Translations
import java.util.Locale
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** Clock-style duration: `mm:ss`, or `HH:mm:ss` from one hour on. */
fun formatClock(totalSeconds: Int): String {
    val seconds = totalSeconds.coerceAtLeast(0)
    val hours = seconds / 3600
    val minutes = (seconds % 3600) / 60
    val rest = seconds % 60
    return if (hours > 0) {
        String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, rest)
    } else {
        String.format(Locale.US, "%02d:%02d", minutes, rest)
    }
}

/**
 * Spoken-style duration such as "01 hr 12 min", matching the web app: seconds
 * are only shown below one hour, minutes are dropped for whole hours.
 */
fun Translations.humanDuration(totalSeconds: Int, exact: Boolean = false): String {
    val seconds = totalSeconds.coerceAtLeast(0)
    val days = seconds / 86_400
    val hours = (seconds % 86_400) / 3600
    val minutes = (seconds % 3600) / 60
    val rest = seconds % 60
    fun two(value: Int) = String.format(Locale.US, "%02d", value)

    val parts = mutableListOf<String>()
    if (days > 0) parts += plural("time.days", days, "days" to two(days))
    if (hours > 0) parts += t("time.hour", "hour" to two(hours))
    if (exact) {
        parts += t("time.minutes", "minutes" to two(minutes))
        parts += t("time.seconds", "seconds" to two(rest))
    } else {
        if (!(hours > 0 && minutes == 0)) parts += t("time.minutes", "minutes" to two(minutes))
        if (hours == 0 && rest != 0) parts += t("time.seconds", "seconds" to two(rest))
    }
    return parts.joinToString(" ")
}

fun formatBytes(bytes: Long, decimals: Int = 2): String {
    if (bytes <= 0) return "0 Bytes"
    val units = listOf("Bytes", "KiB", "MiB", "GiB", "TiB", "PiB")
    val index = floor(ln(bytes.toDouble()) / ln(1024.0)).toInt().coerceIn(0, units.lastIndex)
    val value = bytes / 1024.0.pow(index)
    return String.format(Locale.US, "%,.${decimals}f %s", value, units[index])
}

/**
 * Average color of [bitmap] (root mean square per channel, like the web
 * `fast-average-color` "sqrt" algorithm), used to tint detail-page headers.
 */
fun averageColor(bitmap: Bitmap): Color? {
    if (bitmap.width <= 0 || bitmap.height <= 0) return null
    val sample = runCatching {
        val source = if (bitmap.config == Bitmap.Config.HARDWARE) {
            bitmap.copy(Bitmap.Config.ARGB_8888, false)
        } else {
            bitmap
        }
        Bitmap.createScaledBitmap(source, AVERAGE_SAMPLE_SIZE, AVERAGE_SAMPLE_SIZE, true)
    }.getOrNull() ?: return null

    val pixels = IntArray(AVERAGE_SAMPLE_SIZE * AVERAGE_SAMPLE_SIZE)
    sample.getPixels(pixels, 0, AVERAGE_SAMPLE_SIZE, 0, 0, AVERAGE_SAMPLE_SIZE, AVERAGE_SAMPLE_SIZE)
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var count = 0
    for (pixel in pixels) {
        if ((pixel ushr 24) < 128) continue
        val r = (pixel shr 16) and 0xFF
        val g = (pixel shr 8) and 0xFF
        val b = pixel and 0xFF
        red += (r * r).toDouble()
        green += (g * g).toDouble()
        blue += (b * b).toDouble()
        count++
    }
    if (count == 0) return null
    return Color(
        red = sqrt(red / count).roundToInt().coerceIn(0, 255),
        green = sqrt(green / count).roundToInt().coerceIn(0, 255),
        blue = sqrt(blue / count).roundToInt().coerceIn(0, 255),
    )
}

private const val AVERAGE_SAMPLE_SIZE = 32
