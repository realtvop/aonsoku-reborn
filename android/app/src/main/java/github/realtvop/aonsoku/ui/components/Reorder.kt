package github.realtvop.aonsoku.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.zIndex
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Drag-to-reorder for the rows of a lazy column. A row is picked up by its
 * handle ([reorderHandle]) and follows the finger ([reorderItem]). Whenever it
 * is dragged over another row the owner is asked to move it in its own list,
 * so the column always lays out the order that a drop would produce.
 */
@Stable
class ReorderState internal constructor(
    val listState: LazyListState,
    private val scope: CoroutineScope,
) {
    internal var canMove: (from: Any, to: Any) -> Boolean = { _, _ -> true }
    internal var onMove: (from: Any, to: Any) -> Unit = { _, _ -> }
    internal var onDrop: (key: Any) -> Unit = {}
    internal var onLift: () -> Unit = {}

    /** Key of the row under the finger, if any. */
    var draggingKey: Any? by mutableStateOf(null)
        private set

    private var draggedDelta by mutableFloatStateOf(0f)
    private var initialOffset by mutableIntStateOf(0)

    /** Index the dragged row gets once the column has laid out the last move. */
    private var pendingIndex: Int? = null
    private var settlingKey: Any? by mutableStateOf(null)
    private val settle = Animatable(0f)
    private var scrollJob: Job? = null

    private fun itemFor(key: Any): LazyListItemInfo? =
        listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key }

    /** True while the row is dragged or still settling into its slot. */
    fun isLifted(key: Any): Boolean = key == draggingKey || key == settlingKey

    /** Vertical translation that keeps the row with [key] under the finger. */
    fun offsetFor(key: Any): Float = when (key) {
        draggingKey -> itemFor(key)?.let { initialOffset + draggedDelta - it.offset } ?: 0f
        settlingKey -> settle.value
        else -> 0f
    }

    fun start(key: Any) {
        val item = itemFor(key) ?: return
        settlingKey = null
        draggingKey = key
        initialOffset = item.offset
        draggedDelta = 0f
        pendingIndex = null
        scrollJob?.cancel()
        scrollJob = scope.launch { autoScroll() }
        onLift()
    }

    fun dragBy(delta: Float) {
        if (draggingKey == null) return
        draggedDelta += delta
        moveIfNeeded()
    }

    fun end() {
        val key = draggingKey ?: return
        scrollJob?.cancel()
        scrollJob = null
        val restingOffset = offsetFor(key)
        draggingKey = null
        draggedDelta = 0f
        pendingIndex = null
        settlingKey = key
        // Undispatched so the row keeps its position until the animation runs.
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            settle.snapTo(restingOffset)
            settle.animateTo(
                targetValue = 0f,
                animationSpec = spring(
                    stiffness = Spring.StiffnessMediumLow,
                    visibilityThreshold = 1f,
                ),
            )
            if (settlingKey == key) settlingKey = null
        }
        onDrop(key)
    }

    private fun moveIfNeeded() {
        val key = draggingKey ?: return
        val item = itemFor(key) ?: return
        pendingIndex?.let { expected ->
            // The previous move has not been laid out yet; its positions are stale.
            if (item.index != expected) return
            pendingIndex = null
        }
        val middle = initialOffset + draggedDelta + item.size / 2f
        val target = listState.layoutInfo.visibleItemsInfo.firstOrNull { other ->
            other.key != key &&
                middle >= other.offset &&
                middle <= other.offset + other.size &&
                canMove(key, other.key)
        } ?: return
        // A lazy list follows its first visible item by key; when that item is
        // one of the two that swap, pin the scroll position instead.
        val first = listState.firstVisibleItemIndex
        if (item.index == first || target.index == first) {
            listState.requestScrollToItem(first, listState.firstVisibleItemScrollOffset)
        }
        pendingIndex = target.index
        onMove(key, target.key)
    }

    /** Scrolls the column while the dragged row is held past one of its edges. */
    private suspend fun autoScroll() {
        while (true) {
            withFrameNanos { }
            val key = draggingKey ?: return
            val item = itemFor(key) ?: continue
            val info = listState.layoutInfo
            val top = initialOffset + draggedDelta
            val bottom = top + item.size
            val overshoot = when {
                bottom > info.viewportEndOffset -> bottom - info.viewportEndOffset
                top < info.viewportStartOffset -> top - info.viewportStartOffset
                else -> 0f
            }
            if (overshoot == 0f) continue
            val step = (overshoot * AUTO_SCROLL_FACTOR).coerceIn(-AUTO_SCROLL_MAX, AUTO_SCROLL_MAX)
            if (listState.scrollBy(step) != 0f) moveIfNeeded()
        }
    }

    private companion object {
        const val AUTO_SCROLL_FACTOR = 0.2f
        const val AUTO_SCROLL_MAX = 48f
    }
}

/**
 * [canMove] limits a row to the rows it may trade places with, [onMove] moves
 * it in the owner's list to where the other row is, and [onDrop] reports the
 * end of the drag, at which point the owner commits the new order.
 */
@Composable
fun rememberReorderState(
    listState: LazyListState,
    canMove: (from: Any, to: Any) -> Boolean,
    onMove: (from: Any, to: Any) -> Unit,
    onDrop: (key: Any) -> Unit,
    onLift: () -> Unit = {},
): ReorderState {
    val scope = rememberCoroutineScope()
    val state = remember(listState, scope) { ReorderState(listState, scope) }
    SideEffect {
        state.canMove = canMove
        state.onMove = onMove
        state.onDrop = onDrop
        state.onLift = onLift
    }
    return state
}

/** Placement of a reorderable row: under the finger while lifted, animated otherwise. */
fun Modifier.reorderItem(scope: LazyItemScope, state: ReorderState, key: Any): Modifier =
    if (state.isLifted(key)) {
        zIndex(1f).graphicsLayer { translationY = state.offsetFor(key) }
    } else {
        with(scope) { animateItem() }
    }

/** Makes the element a drag handle that picks its row up as soon as it is touched. */
fun Modifier.reorderHandle(state: ReorderState, key: Any): Modifier =
    pointerInput(state, key) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            down.consume()
            state.start(key)
            try {
                drag(down.id) { change ->
                    state.dragBy(change.positionChange().y)
                    change.consume()
                }
            } finally {
                state.end()
            }
        }
    }
