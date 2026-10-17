package github.realtvop.aonsoku.ui.components

import github.realtvop.aonsoku.data.Loadable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Holds the latest value of a cached-then-fresh read and can run it again.
 * While reloading, the value that is already shown stays in place.
 */
class LoadableSource<T>(
    private val scope: CoroutineScope,
    private val source: () -> Flow<Loadable<T>>,
) {
    private val _state = MutableStateFlow<Loadable<T>>(Loadable.Loading)
    private var job: Job? = null

    val state: StateFlow<Loadable<T>> = _state.asStateFlow()

    val value: T? get() = (_state.value as? Loadable.Ready<T>)?.value

    init {
        reload()
    }

    fun reload() {
        job?.cancel()
        job = scope.launch {
            source().collect { next ->
                val showing = _state.value is Loadable.Ready
                // A failed or pending reload does not blank a page that already has content.
                if (showing && next !is Loadable.Ready) {
                    if (next is Loadable.Failed && next.notFound) _state.value = next
                    return@collect
                }
                _state.value = next
            }
        }
    }

    /** Replaces the shown value, for optimistic edits. */
    fun set(value: T) {
        _state.value = Loadable.Ready(value)
    }

    /** Stops a running read and keeps what is shown, for content that is going away. */
    fun stop() {
        job?.cancel()
    }
}
