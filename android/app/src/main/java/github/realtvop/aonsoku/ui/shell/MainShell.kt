package github.realtvop.aonsoku.ui.shell

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.rememberNavController
import github.realtvop.aonsoku.ui.navigation.AppNavigator
import github.realtvop.aonsoku.ui.navigation.HomeRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.TopLevelTab
import github.realtvop.aonsoku.ui.navigation.appDestinations

/**
 * Bottom space taken by the floating navigation and player. Scrolling pages
 * add it to their content padding so the last items clear the floating UI.
 */
val LocalFloatingBarsPadding = staticCompositionLocalOf { 0.dp }

private val FloatingBarsBottomMargin = 12.dp
private val FloatingBarsSpacing = 8.dp

@Composable
fun MainShell() {
    val navController = rememberNavController()
    val initialTab = rememberSaveable { TopLevelTab.Home }
    val navigator = remember(navController) { AppNavigator(navController, initialTab) }

    DisposableEffect(navController, navigator) {
        val listener = NavController.OnDestinationChangedListener { _, destination, _ ->
            navigator.onDestinationChanged(destination)
        }
        navController.addOnDestinationChangedListener(listener)
        onDispose { navController.removeOnDestinationChangedListener(listener) }
    }

    val navigationBarInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val floatingBarsHeight = floatingBarsHeight(hasPlayer = false)
    val imeVisible = WindowInsets.isImeVisible

    CompositionLocalProvider(
        LocalNavigator provides navigator,
        LocalFloatingBarsPadding provides floatingBarsHeight + navigationBarInset,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background),
        ) {
            val spatial = MaterialTheme.motionScheme.defaultSpatialSpec<IntOffset>()
            val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
            NavHost(
                navController = navController,
                startDestination = HomeRoute,
                modifier = Modifier.fillMaxSize(),
                enterTransition = { forwardEnter(spatial, effects) },
                exitTransition = { forwardExit(effects) },
                popEnterTransition = { backEnter(effects) },
                popExitTransition = { backExit(spatial, effects) },
            ) {
                appDestinations()
            }

            AnimatedVisibility(
                visible = !imeVisible,
                modifier = Modifier.align(Alignment.BottomCenter),
                enter = slideInVertically(spatial) { it } + fadeIn(effects),
                exit = slideOutVertically(spatial) { it } + fadeOut(effects),
            ) {
                Column(
                    modifier = Modifier
                        .navigationBarsPadding()
                        .padding(bottom = FloatingBarsBottomMargin),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(FloatingBarsSpacing),
                ) {
                    FloatingNavBar(
                        currentTab = navigator.currentTab,
                        onSelect = navigator::selectTab,
                    )
                }
            }
        }
    }
}

private fun floatingBarsHeight(hasPlayer: Boolean): Dp {
    val player = if (hasPlayer) MiniPlayerHeight + FloatingBarsSpacing else 0.dp
    return FloatingNavBarHeight + FloatingBarsBottomMargin + FloatingBarsSpacing + player
}

/** Height reserved for the floating mini player once a queue exists. */
val MiniPlayerHeight = 64.dp

/** Content padding for a scrolling page below the system bars and above the floating UI. */
@Composable
fun floatingBarsContentPadding(top: Dp = 0.dp, horizontal: Dp = 0.dp): PaddingValues =
    PaddingValues(
        start = horizontal,
        end = horizontal,
        top = top,
        bottom = LocalFloatingBarsPadding.current + 8.dp,
    )

private fun forwardEnter(
    spatial: FiniteAnimationSpec<IntOffset>,
    effects: FiniteAnimationSpec<Float>,
): EnterTransition = slideInHorizontally(spatial) { it / 8 } + fadeIn(effects)

private fun forwardExit(effects: FiniteAnimationSpec<Float>): ExitTransition =
    fadeOut(effects) + scaleOut(effects, targetScale = 0.98f)

private fun backEnter(effects: FiniteAnimationSpec<Float>): EnterTransition =
    fadeIn(effects) + scaleIn(effects, initialScale = 0.98f)

private fun backExit(
    spatial: FiniteAnimationSpec<IntOffset>,
    effects: FiniteAnimationSpec<Float>,
): ExitTransition = slideOutHorizontally(spatial) { it / 8 } + fadeOut(effects)
