package github.realtvop.aonsoku.utils

import java.util.Locale

object TimeUtils {
    fun formatDuration(seconds: Int): String {
        if (seconds <= 0) return "0:00"
        val hours = seconds / 3600
        val minutes = (seconds % 3600) / 60
        val secs = seconds % 60
        return if (hours > 0) {
            String.format(Locale.US, "%d:%02d:%02d", hours, minutes, secs)
        } else {
            String.format(Locale.US, "%d:%02d", minutes, secs)
        }
    }

    fun formatDuration(seconds: Double): String {
        return formatDuration(seconds.toInt())
    }
}
