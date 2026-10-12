package github.realtvop.aonsoku.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.AppGraph
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.I18n
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.session.SessionState
import github.realtvop.aonsoku.theme.AonsokuTheme
import github.realtvop.aonsoku.theme.resolveDarkTheme
import github.realtvop.aonsoku.ui.components.ToastHost
import github.realtvop.aonsoku.ui.login.LoginScreen
import github.realtvop.aonsoku.ui.shell.MainShell

/** Keeps toasts above the floating navigation bar of the signed-in shell. */
private val FloatingBarsReserve = 88.dp

@Composable
fun AonsokuApp(graph: AppGraph, onThemeResolved: @Composable (dark: Boolean) -> Unit = {}) {
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val session by graph.session.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val strings = remember(settings.language) { I18n.load(context, settings.language) }
    val dark = resolveDarkTheme(settings.themeMode)

    AonsokuTheme(settings = settings, dark = dark) {
        onThemeResolved(dark)
        CompositionLocalProvider(
            LocalAppGraph provides graph,
            LocalStrings provides strings,
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
                    ToastHost(
                        toaster = graph.toaster,
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))
                            .padding(bottom = if (signedIn) FloatingBarsReserve else 0.dp),
                    )
                }
            }
        }
    }
}
