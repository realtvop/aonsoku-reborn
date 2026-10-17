package github.realtvop.aonsoku.ui.components

import androidx.compose.runtime.Composable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph

/**
 * A screen's view model, created from the application graph and scoped to the
 * current navigation entry so it survives while the page is on the back stack.
 */
@Composable
inline fun <reified VM : ViewModel> graphViewModel(
    key: String? = null,
    noinline create: (AppGraph) -> VM,
): VM {
    val graph = LocalAppGraph.current
    return viewModel(
        key = key,
        factory = viewModelFactory { initializer { create(graph) } },
    )
}
