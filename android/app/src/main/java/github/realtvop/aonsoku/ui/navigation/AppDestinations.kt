package github.realtvop.aonsoku.ui.navigation

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

    composable<SettingsRoute> { SettingsScreen(it.toRoute()) }
}
