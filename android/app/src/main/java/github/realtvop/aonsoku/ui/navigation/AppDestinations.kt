package github.realtvop.aonsoku.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.RootHeader

/** Registers every destination of the signed-in app. */
fun NavGraphBuilder.appDestinations() {
    composable<HomeRoute> { PlaceholderPage(t("sidebar.home")) }
    composable<LibraryRoute> { PlaceholderPage(t("sidebar.library")) }
    composable<SearchRoute> { PlaceholderPage(t("sidebar.miniSearch")) }
    composable<SettingsRoute> { PlaceholderPage(t("settings.label")) }
}

@Composable
private fun PlaceholderPage(title: String) {
    Column(modifier = Modifier.fillMaxSize()) {
        RootHeader(title = title)
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                text = t("generic.loading"),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
