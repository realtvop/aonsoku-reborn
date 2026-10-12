package github.realtvop.aonsoku.ui.navigation

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable
import androidx.navigation.toRoute
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.detail.AlbumScreen
import github.realtvop.aonsoku.ui.detail.ArtistScreen
import github.realtvop.aonsoku.ui.detail.FavoritesScreen
import github.realtvop.aonsoku.ui.detail.PlaylistScreen
import github.realtvop.aonsoku.ui.home.HomeScreen
import github.realtvop.aonsoku.ui.library.AlbumsScreen
import github.realtvop.aonsoku.ui.library.ArtistsScreen
import github.realtvop.aonsoku.ui.library.LibraryScreen
import github.realtvop.aonsoku.ui.library.RadiosScreen
import github.realtvop.aonsoku.ui.library.SongsScreen
import github.realtvop.aonsoku.ui.search.SearchScreen

/** Registers every destination of the signed-in app. */
fun NavGraphBuilder.appDestinations() {
    composable<HomeRoute> { HomeScreen() }
    composable<LibraryRoute> { LibraryScreen() }
    composable<SearchRoute> { SearchScreen() }

    composable<ArtistsRoute> { ArtistsScreen() }
    composable<SongsRoute> { SongsScreen(it.toRoute()) }
    composable<AlbumsRoute> { AlbumsScreen(it.toRoute()) }
    composable<FavoritesRoute> { FavoritesScreen() }
    composable<RadiosRoute> { RadiosScreen() }

    composable<AlbumRoute> { AlbumScreen(it.toRoute()) }
    composable<ArtistRoute> { ArtistScreen(it.toRoute()) }
    composable<PlaylistRoute> { PlaylistScreen(it.toRoute()) }

    composable<SettingsRoute> { PlaceholderPage(t("settings.label")) }
}

@Composable
private fun PlaceholderPage(title: String) {
    Box(modifier = Modifier.fillMaxSize()) {
        Text(
            text = t("generic.loading"),
            modifier = Modifier.align(Alignment.Center),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SubPageTopBar(title = title, collapsed = true)
    }
}
