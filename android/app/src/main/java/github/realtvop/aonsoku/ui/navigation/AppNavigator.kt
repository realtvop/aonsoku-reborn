package github.realtvop.aonsoku.ui.navigation

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.navigation.NavDestination
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController

/**
 * Navigation entry point handed to screens. Each top-level tab keeps its own
 * back stack; detail pages are pushed onto the stack of the tab they were
 * opened from.
 */
@Stable
class AppNavigator(
    val controller: NavHostController,
    initialTab: TopLevelTab = TopLevelTab.Home,
) {
    var currentTab by mutableStateOf(initialTab)
        private set

    fun open(route: Any) {
        controller.navigate(route) { launchSingleTop = true }
    }

    fun back() {
        if (!controller.popBackStack()) {
            selectTab(TopLevelTab.Home)
        }
    }

    /** Switch tabs, or return to the tab root when it is already selected. */
    fun selectTab(tab: TopLevelTab) {
        val route = tab.route()
        if (tab == currentTab) {
            controller.popBackStack(route, inclusive = false)
            return
        }
        currentTab = tab
        controller.navigate(route) {
            popUpTo(controller.graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
    }

    /** Keeps [currentTab] in sync when system back lands on another tab root. */
    fun onDestinationChanged(destination: NavDestination) {
        tabOf(destination)?.let { currentTab = it }
    }

    private fun tabOf(destination: NavDestination): TopLevelTab? = when {
        destination.hasRoute<HomeRoute>() -> TopLevelTab.Home
        destination.hasRoute<LibraryRoute>() -> TopLevelTab.Library
        destination.hasRoute<SearchRoute>() -> TopLevelTab.Search
        else -> null
    }

    private fun TopLevelTab.route(): Any = when (this) {
        TopLevelTab.Home -> HomeRoute
        TopLevelTab.Library -> LibraryRoute
        TopLevelTab.Search -> SearchRoute
    }
}

val LocalNavigator = staticCompositionLocalOf<AppNavigator> {
    error("AppNavigator is not provided")
}
