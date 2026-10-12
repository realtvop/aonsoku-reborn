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
import androidx.navigation.toRoute
import kotlin.reflect.KClass

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

    /**
     * Runs whenever a page is requested, also when it is already open. The
     * shell uses it to close what covers the pages, such as the player.
     */
    var onOpen: () -> Unit = {}

    /**
     * Pushes [route] unless that exact page is already on top (a second tap
     * on the same link). Another album or artist is a new page, so this must
     * not be a single-top launch, which would replace the page that is open.
     */
    fun open(route: Any) {
        onOpen()
        val current = controller.currentBackStackEntry
        val type: KClass<out Any> = route::class
        val alreadyOpen = current != null &&
            current.destination.hasRoute(type) &&
            runCatching { current.toRoute<Any>(type) == route }.getOrDefault(false)
        if (alreadyOpen) return
        controller.navigate(route)
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
