package github.realtvop.aonsoku.ui.overlays

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import github.realtvop.aonsoku.i18n.t

/**
 * Full-screen artwork (the web "lightbox"): pinch or double tap to zoom, drag
 * to pan, tap to close.
 */
@Composable
fun ArtworkViewer(overlay: Overlay.Artwork, controller: OverlayController) {
    Dialog(
        onDismissRequest = controller::dismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        var scale by remember { mutableFloatStateOf(1f) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        var size by remember { mutableStateOf(IntSize.Zero) }

        /** Keeps the zoomed image from being dragged out of the screen. */
        fun bounded(value: Offset, zoom: Float): Offset {
            val maxX = size.width * (zoom - 1f) / 2f
            val maxY = size.height * (zoom - 1f) / 2f
            return Offset(value.x.coerceIn(-maxX, maxX), value.y.coerceIn(-maxY, maxY))
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.92f))
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { controller.dismiss() },
                        onDoubleTap = {
                            scale = if (scale > 1f) 1f else DOUBLE_TAP_ZOOM
                            offset = Offset.Zero
                        },
                    )
                }
                .pointerInput(Unit) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        size = this.size
                        scale = (scale * zoom).coerceIn(1f, MAX_ZOOM)
                        offset = bounded(offset + pan, scale)
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            AsyncImage(
                model = overlay.art,
                contentDescription = overlay.title,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        translationX = offset.x
                        translationY = offset.y
                    },
            )
            IconButton(
                onClick = controller::dismiss,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .statusBarsPadding()
                    .padding(4.dp),
                colors = IconButtonDefaults.iconButtonColors(contentColor = Color.White),
            ) {
                Icon(
                    Icons.AutoMirrored.Rounded.ArrowBack,
                    contentDescription = t("navigation.back"),
                )
            }
        }
    }
}

private const val DOUBLE_TAP_ZOOM = 2.5f
private const val MAX_ZOOM = 5f
