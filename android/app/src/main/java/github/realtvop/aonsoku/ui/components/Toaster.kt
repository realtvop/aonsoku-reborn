package github.realtvop.aonsoku.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarVisuals
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.collectLatest

enum class ToastKind { Success, Error, Info }

data class Toast(val message: String, val kind: ToastKind = ToastKind.Info)

/** App-wide transient messages, the native counterpart of the web toasts. */
class Toaster {
    private val _toasts = MutableSharedFlow<Toast>(extraBufferCapacity = 8)

    val toasts: SharedFlow<Toast> = _toasts.asSharedFlow()

    fun success(message: String) = show(Toast(message, ToastKind.Success))

    fun error(message: String) = show(Toast(message, ToastKind.Error))

    fun info(message: String) = show(Toast(message, ToastKind.Info))

    fun show(toast: Toast) {
        _toasts.tryEmit(toast)
    }
}

private class ToastVisuals(val toast: Toast) : SnackbarVisuals {
    override val message: String = toast.message
    override val actionLabel: String? = null
    override val withDismissAction: Boolean = false
    override val duration: SnackbarDuration = SnackbarDuration.Short
}

@Composable
fun ToastHost(toaster: Toaster, modifier: Modifier = Modifier) {
    val hostState = remember { SnackbarHostState() }
    LaunchedEffect(toaster) {
        // Showing a message suspends until it leaves, so a newer one cancels
        // it and takes its place instead of waiting for its turn.
        toaster.toasts.collectLatest { toast -> hostState.showSnackbar(ToastVisuals(toast)) }
    }
    SnackbarHost(hostState = hostState, modifier = modifier) { data ->
        val kind = (data.visuals as? ToastVisuals)?.toast?.kind ?: ToastKind.Info
        val (icon, tint) = when (kind) {
            ToastKind.Success -> Icons.Rounded.CheckCircle to MaterialTheme.colorScheme.primary
            ToastKind.Error -> Icons.Rounded.ErrorOutline to MaterialTheme.colorScheme.error
            ToastKind.Info -> Icons.Rounded.Info to MaterialTheme.colorScheme.onSurfaceVariant
        }
        Snackbar(
            // A tap sends the message away before its time is up.
            modifier = Modifier
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .clip(MaterialTheme.shapes.large)
                .clickable { data.dismiss() },
            shape = MaterialTheme.shapes.large,
            containerColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text(data.visuals.message, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}
