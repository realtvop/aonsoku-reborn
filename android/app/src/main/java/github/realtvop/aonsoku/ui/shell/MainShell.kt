package github.realtvop.aonsoku.ui.shell

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.rememberNavController
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.ui.navigation.AppNavigator
import github.realtvop.aonsoku.ui.navigation.HomeRoute
import github.realtvop.aonsoku.ui.navigation.LibraryRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SearchRoute
import github.realtvop.aonsoku.ui.navigation.TopLevelTab
import github.realtvop.aonsoku.ui.navigation.appDestinations
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.OverlayController
import github.realtvop.aonsoku.ui.overlays.OverlayHost
import github.realtvop.aonsoku.ui.player.FullscreenPlayer
import github.realtvop.aonsoku.ui.player.LocalPlayerSheetLink
import github.realtvop.aonsoku.ui.player.MiniPlayer
import github.realtvop.aonsoku.ui.player.QueueReplacementDialog
import github.realtvop.aonsoku.ui.player.rememberFullscreenPlayerState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Bottom space taken by the floating navigation and player. Scrolling pages
 * add it to their content padding so the last items clear the floating UI.
 */
val LocalFloatingBarsPadding = staticCompositionLocalOf { 0.dp }

private val FloatingBarsBottomMargin = 12.dp
private val FloatingBarsSpacing = 8.dp

/** How long a request to open the player waits for playback to bind after a start. */
private const val OPEN_REQUEST_WAIT_MS = 5_000L

@Composable
fun MainShell() {
    val navController = rememberNavController()
    val initialTab = rememberSaveable { TopLevelTab.Home }
    val navigator = remember(navController) { AppNavigator(navController, initialTab) }
    val overlays = remember { OverlayController() }
    val fullscreenPlayer = rememberFullscreenPlayerState()
    // A link followed from the player or one of its menus leads to a page below it.
    SideEffect { navigator.onOpen = fullscreenPlayer::close }

    DisposableEffect(navController, navigator) {
        val listener = NavController.OnDestinationChangedListener { _, destination, _ ->
            navigator.onDestinationChanged(destination)
        }
        navController.addOnDestinationChangedListener(listener)
        onDispose { navController.removeOnDestinationChangedListener(listener) }
    }

    val graph = LocalAppGraph.current
    val playerState by graph.player.state.collectAsStateWithLifecycle()
    val navigationBarInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val floatingBarsHeight = floatingBarsHeight(hasPlayer = playerState.hasMedia)
    val imeVisible = WindowInsets.isImeVisible

    NotificationPermissionEffect(isPlaying = playerState.isPlaying)

    // A tap on the playback notification opens the player, once it has bound.
    val playerLink = LocalPlayerSheetLink.current
    val openRequested by playerLink.openRequested.collectAsStateWithLifecycle()
    LaunchedEffect(openRequested) {
        if (!openRequested) return@LaunchedEffect
        playerLink.consumeOpenRequest()
        withTimeoutOrNull(OPEN_REQUEST_WAIT_MS) { graph.player.state.first { it.hasMedia } }
            ?.let { fullscreenPlayer.open() }
    }

    CompositionLocalProvider(
        LocalNavigator provides navigator,
        LocalOverlays provides overlays,
        LocalFloatingBarsPadding provides floatingBarsHeight + navigationBarInset,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background),
        ) {
            val spatial = MaterialTheme.motionScheme.defaultSpatialSpec<IntOffset>()
            val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
            // The pages and bars are out of reach while the player covers them.
            val covered = fullscreenPlayer.isOpen && playerState.hasMedia
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .then(if (covered) Modifier.clearAndSetSemantics { } else Modifier),
            ) {
                NavHost(
                    navController = navController,
                    startDestination = HomeRoute,
                    modifier = Modifier.fillMaxSize(),
                    enterTransition = {
                        if (targetState.destination.isBottomNavigationDestination()) {
                            EnterTransition.None
                        } else {
                            forwardEnter(spatial, effects)
                        }
                    },
                    exitTransition = {
                        if (targetState.destination.isBottomNavigationDestination()) {
                            ExitTransition.None
                        } else {
                            forwardExit(effects)
                        }
                    },
                    popEnterTransition = { EnterTransition.None },
                    popExitTransition = { backExit() },
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
                        AnimatedVisibility(
                            visible = playerState.hasMedia,
                            enter = slideInVertically(spatial) { it / 2 } + fadeIn(effects),
                            exit = slideOutVertically(spatial) { it / 2 } + fadeOut(effects),
                        ) {
                            MiniPlayer(
                                state = playerState,
                                onExpand = { fullscreenPlayer.open() },
                                modifier = Modifier
                                    .padding(horizontal = 12.dp)
                                    .widthIn(max = 560.dp),
                            )
                        }
                        FloatingNavBar(
                            currentTab = navigator.currentTab,
                            onSelect = navigator::selectTab,
                        )
                    }
                }
            }

            FullscreenPlayer(playerState = playerState, sheet = fullscreenPlayer)
            QueueReplacementDialog()
            OverlayHost(overlays)
        }
    }
}

/**
 * Playback shows a media notification; ask for the permission once playback
 * first starts (Android 13+). Declining only hides the notification.
 */
@Composable
private fun NotificationPermissionEffect(isPlaying: Boolean) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val context = LocalContext.current
    var asked by rememberSaveable { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {}
    LaunchedEffect(isPlaying) {
        if (!isPlaying || asked) return@LaunchedEffect
        asked = true
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
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

private fun androidx.navigation.NavDestination.isBottomNavigationDestination(): Boolean =
    hasRoute<HomeRoute>() || hasRoute<LibraryRoute>() || hasRoute<SearchRoute>()

/**
 * Going back, the page on top shrinks and then fades away while the page below
 * stays as it is, so a back gesture shows where it leads. A back gesture moves
 * through this transition as it goes, so it uses tweens, which never overshoot.
 */
private fun backExit(): ExitTransition =
    scaleOut(tween(BACK_MS, easing = FastOutSlowInEasing), targetScale = 0.9f) +
        fadeOut(tween(BACK_FADE_MS, delayMillis = BACK_MS - BACK_FADE_MS))

private const val BACK_MS = 350
private const val BACK_FADE_MS = 120
