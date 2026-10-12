package github.realtvop.aonsoku.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.zIndex
import kotlin.math.roundToInt

/**
 * A short list whose rows are put in order by dragging their handles. Every
 * row is composed and equally high, which suits a handful of rows inside a
 * page; long lists use the lazy list reorder instead.
 *
 * [row] gets the modifier for its drag handle and whether it is being dragged.
 * [onMove] runs when a row is dropped at another place.
 */
@Composable
fun <T : Any> ReorderableColumn(
    items: List<T>,
    rowHeight: Dp,
    onMove: (from: Int, to: Int) -> Unit,
    modifier: Modifier = Modifier,
    row: @Composable (index: Int, item: T, handle: Modifier, lifted: Boolean) -> Unit,
) {
    val heightPx = with(LocalDensity.current) { rowHeight.toPx() }
    val count by rememberUpdatedState(items.size)
    val move by rememberUpdatedState(onMove)
    // The place the dragged row started from, and how far it has been dragged.
    var origin by remember { mutableStateOf<Int?>(null) }
    var offset by remember { mutableFloatStateOf(0f) }

    fun targetOf(from: Int): Int = (from + (offset / heightPx).roundToInt()).coerceIn(0, count - 1)

    val from = origin
    val target = from?.let(::targetOf)
    Column(modifier = modifier) {
        items.forEachIndexed { index, item ->
            key(item) {
                val lifted = from == index
                // Rows between where the dragged one came from and where it is make room.
                val shift = when {
                    from == null || target == null || lifted -> 0f
                    index in (from + 1)..target -> -heightPx
                    index in target until from -> heightPx
                    else -> 0f
                }
                val settled by animateFloatAsState(
                    targetValue = shift,
                    // After a drop the rows are laid out in their new places already.
                    animationSpec = if (from == null) snap() else MaterialTheme.motionScheme.fastSpatialSpec(),
                    label = "reorderShift",
                )
                val handle = Modifier.pointerInput(index) {
                    detectDragGestures(
                        onDragStart = {
                            origin = index
                            offset = 0f
                        },
                        onDragEnd = {
                            val to = targetOf(index)
                            origin = null
                            offset = 0f
                            if (to != index) move(index, to)
                        },
                        onDragCancel = {
                            origin = null
                            offset = 0f
                        },
                    ) { change, amount ->
                        change.consume()
                        offset = (offset + amount.y).coerceIn(-index * heightPx, (count - 1 - index) * heightPx)
                    }
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(rowHeight)
                        .zIndex(if (lifted) 1f else 0f)
                        .graphicsLayer { translationY = if (lifted) offset else settled },
                ) {
                    row(index, item, handle, lifted)
                }
            }
        }
    }
}
