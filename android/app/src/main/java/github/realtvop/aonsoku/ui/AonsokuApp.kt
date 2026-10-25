package github.realtvop.aonsoku.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.I18n
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.session.SessionState
import github.realtvop.aonsoku.theme.AonsokuTheme
import github.realtvop.aonsoku.theme.LocalSystemBarsOverride
import github.realtvop.aonsoku.theme.resolveDarkTheme
import github.realtvop.aonsoku.ui.components.ToastHost
import github.realtvop.aonsoku.ui.login.LoginScreen
import github.realtvop.aonsoku.ui.player.LocalPlayerSheetLink
import github.realtvop.aonsoku.ui.player.PlayerSheetLink
import github.realtvop.aonsoku.ui.shell.MainShell

/**
 * [systemBars] is composed with whether the content behind the system bars is
 * dark, which is the theme unless a surface such as the full-screen player
 * covers the bars with its own color.
 */
@Composable
fun AonsokuApp(
    graph: AppGraph,
    playerLink: PlayerSheetLink = remember { PlayerSheetLink() },
    systemBars: @Composable (dark: Boolean) -> Unit = {},
) {
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val session by graph.session.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val strings = remember(settings.language) { I18n.load(context, settings.language) }
    val dark = resolveDarkTheme(settings.themeMode)
    val barsOverride = remember { mutableStateOf<Boolean?>(null) }

    AonsokuTheme(settings = settings, dark = dark) {
        systemBars(barsOverride.value ?: dark)
        CompositionLocalProvider(
            LocalAppGraph provides graph,
            LocalStrings provides strings,
            LocalSystemBarsOverride provides barsOverride,
            LocalPlayerSheetLink provides playerLink,
        ) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.background,
            ) {
                Box(modifier = Modifier.fillMaxSize()) {
                    val signedIn = session is SessionState.SignedIn
                    val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
                    AnimatedContent(
                        targetState = signedIn,
                        transitionSpec = { fadeIn(effects) togetherWith fadeOut(effects) },
                        label = "session",
                    ) { isSignedIn ->
                        if (isSignedIn) MainShell() else LoginScreen()
                    }
                    // At the top, like the web app's: clear of the floating bars, the
                    // keyboard, and the buttons that end a page.
                    ToastHost(
                        toaster = graph.toaster,
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .windowInsetsPadding(
                                WindowInsets.safeDrawing.only(
                                    WindowInsetsSides.Top + WindowInsetsSides.Horizontal,
                                ),
                            ),
                    )
                }
            }
        }
    }
}
