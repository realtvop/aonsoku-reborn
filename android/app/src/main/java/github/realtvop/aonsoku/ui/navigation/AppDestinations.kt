package github.realtvop.aonsoku.ui.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavGraphBuilder
import androidx.navigation.compose.composable
import androidx.navigation.toRoute
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
import github.realtvop.aonsoku.ui.settings.SettingsScreen

/** Registers every destination of the signed-in app. */
fun NavGraphBuilder.appDestinations() {
    page<HomeRoute> { HomeScreen() }
    page<LibraryRoute> { LibraryScreen() }
    page<SearchRoute> { SearchScreen() }

    page<ArtistsRoute> { ArtistsScreen() }
    page<SongsRoute> { SongsScreen(it.toRoute()) }
    page<AlbumsRoute> { AlbumsScreen(it.toRoute()) }
    page<FavoritesRoute> { FavoritesScreen() }
    page<RadiosRoute> { RadiosScreen() }

    page<AlbumRoute> { AlbumScreen(it.toRoute()) }
    page<ArtistRoute> { ArtistScreen(it.toRoute()) }
    page<PlaylistRoute> { PlaylistScreen(it.toRoute()) }

    page<SettingsRoute> { SettingsScreen(it.toRoute()) }
}

/**
 * Registers a page drawn on the app background, so that while going back the
 * page on top hides the one below it wherever it still covers it.
 */
private inline fun <reified T : Any> NavGraphBuilder.page(
    noinline content: @Composable (NavBackStackEntry) -> Unit,
) {
    composable<T> { entry ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background),
        ) {
            content(entry)
        }
    }
}
