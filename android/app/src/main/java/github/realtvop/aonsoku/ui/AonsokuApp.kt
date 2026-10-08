package github.realtvop.aonsoku.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import github.realtvop.aonsoku.ui.player.FullscreenPlayer
import github.realtvop.aonsoku.ui.player.MiniPlayerBar
import github.realtvop.aonsoku.ui.screens.AlbumDetailScreen
import github.realtvop.aonsoku.ui.screens.AlbumsScreen
import github.realtvop.aonsoku.ui.screens.ArtistDetailScreen
import github.realtvop.aonsoku.ui.screens.ArtistsScreen
import github.realtvop.aonsoku.ui.screens.HomeScreen
import github.realtvop.aonsoku.ui.screens.LibraryScreen
import github.realtvop.aonsoku.ui.screens.LoginScreen
import github.realtvop.aonsoku.ui.screens.PlaylistDetailScreen
import github.realtvop.aonsoku.ui.screens.SearchScreen
import github.realtvop.aonsoku.ui.screens.SettingsScreen
import github.realtvop.aonsoku.ui.screens.SongsScreen
import github.realtvop.aonsoku.ui.theme.AonsokuTheme
import github.realtvop.aonsoku.viewmodel.HomeViewModel
import github.realtvop.aonsoku.viewmodel.LibraryViewModel
import github.realtvop.aonsoku.viewmodel.PlaybackViewModel
import github.realtvop.aonsoku.viewmodel.SearchViewModel
import github.realtvop.aonsoku.viewmodel.SessionViewModel

sealed class Screen(val route: String, val title: String) {
    data object Home : Screen("home", "Home")
    data object Library : Screen("library", "Library")
    data object Search : Screen("search", "Search")
    data object AlbumDetail : Screen("album/{albumId}", "Album") {
        fun createRoute(albumId: String) = "album/$albumId"
    }
    data object ArtistDetail : Screen("artist/{artistId}", "Artist") {
        fun createRoute(artistId: String) = "artist/$artistId"
    }
    data object PlaylistDetail : Screen("playlist/{playlistId}", "Playlist") {
        fun createRoute(playlistId: String) = "playlist/$playlistId"
    }
    data object Songs : Screen("songs", "Songs")
    data object Favorites : Screen("favorites", "Favorites")
    data object Albums : Screen("albums", "Albums")
    data object Artists : Screen("artists", "Artists")
    data object Settings : Screen("settings", "Settings")
}

@Composable
fun AonsokuApp(
    sessionViewModel: SessionViewModel = viewModel(),
    playbackViewModel: PlaybackViewModel = viewModel(),
) {
    val isAuthenticated by sessionViewModel.isAuthenticated.collectAsState()
    val themeMode by sessionViewModel.themeMode.collectAsState()
    val dynamicColor by sessionViewModel.dynamicColor.collectAsState()

    val darkTheme = when (themeMode) {
        "dark" -> true
        "light" -> false
        else -> isSystemInDarkTheme()
    }

    AonsokuTheme(
        darkTheme = darkTheme,
        dynamicColor = dynamicColor,
    ) {
        if (!isAuthenticated) {
            LoginScreen(
                sessionViewModel = sessionViewModel,
                onLoginSuccess = {},
            )
        } else {
            val navController = rememberNavController()
            val navBackStackEntry by navController.currentBackStackEntryAsState()
            val currentRoute = navBackStackEntry?.destination?.route

            val bottomNavRoutes = setOf(Screen.Home.route, Screen.Library.route, Screen.Search.route)
            val showBottomNav = currentRoute in bottomNavRoutes

            val homeViewModel: HomeViewModel = viewModel()
            val libraryViewModel: LibraryViewModel = viewModel()
            val searchViewModel: SearchViewModel = viewModel()

            Box(modifier = Modifier.fillMaxSize()) {
                Scaffold(
                    bottomBar = {
                        if (showBottomNav) {
                            NavigationBar {
                                NavigationBarItem(
                                    icon = { Icon(Icons.Default.Home, contentDescription = "Home") },
                                    label = { Text("Home") },
                                    selected = currentRoute == Screen.Home.route,
                                    onClick = {
                                        navController.navigate(Screen.Home.route) {
                                            popUpTo(navController.graph.findStartDestination().id) {
                                                saveState = true
                                            }
                                            launchSingleTop = true
                                            restoreState = true
                                        }
                                    },
                                )
                                NavigationBarItem(
                                    icon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, contentDescription = "Library") },
                                    label = { Text("Library") },
                                    selected = currentRoute == Screen.Library.route,
                                    onClick = {
                                        navController.navigate(Screen.Library.route) {
                                            popUpTo(navController.graph.findStartDestination().id) {
                                                saveState = true
                                            }
                                            launchSingleTop = true
                                            restoreState = true
                                        }
                                    },
                                )
                                NavigationBarItem(
                                    icon = { Icon(Icons.Default.Search, contentDescription = "Search") },
                                    label = { Text("Search") },
                                    selected = currentRoute == Screen.Search.route,
                                    onClick = {
                                        navController.navigate(Screen.Search.route) {
                                            popUpTo(navController.graph.findStartDestination().id) {
                                                saveState = true
                                            }
                                            launchSingleTop = true
                                            restoreState = true
                                        }
                                    },
                                )
                            }
                        }
                    },
                ) { innerPadding ->
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(innerPadding),
                    ) {
                        NavHost(
                            navController = navController,
                            startDestination = Screen.Home.route,
                            modifier = Modifier.fillMaxSize(),
                        ) {
                            composable(Screen.Home.route) {
                                HomeScreen(
                                    homeViewModel = homeViewModel,
                                    sessionViewModel = sessionViewModel,
                                    playbackViewModel = playbackViewModel,
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                    onNavigateToAlbums = {
                                        navController.navigate(Screen.Albums.route)
                                    },
                                    onNavigateToSettings = {
                                        navController.navigate(Screen.Settings.route)
                                    },
                                )
                            }

                            composable(Screen.Library.route) {
                                LibraryScreen(
                                    libraryViewModel = libraryViewModel,
                                    onNavigateToArtists = { navController.navigate(Screen.Artists.route) },
                                    onNavigateToSongs = { navController.navigate(Screen.Songs.route) },
                                    onNavigateToAlbums = { navController.navigate(Screen.Albums.route) },
                                    onNavigateToFavorites = { navController.navigate(Screen.Favorites.route) },
                                    onNavigateToPlaylist = { playlistId ->
                                        navController.navigate(Screen.PlaylistDetail.createRoute(playlistId))
                                    },
                                )
                            }

                            composable(Screen.Search.route) {
                                SearchScreen(
                                    searchViewModel = searchViewModel,
                                    playbackViewModel = playbackViewModel,
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                    onNavigateToArtist = { artistId ->
                                        navController.navigate(Screen.ArtistDetail.createRoute(artistId))
                                    },
                                )
                            }

                            composable(
                                route = Screen.AlbumDetail.route,
                                arguments = listOf(navArgument("albumId") { type = NavType.StringType }),
                            ) { backStackEntry ->
                                val albumId = backStackEntry.arguments?.getString("albumId") ?: return@composable
                                AlbumDetailScreen(
                                    albumId = albumId,
                                    playbackViewModel = playbackViewModel,
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToArtist = { artistId ->
                                        navController.navigate(Screen.ArtistDetail.createRoute(artistId))
                                    },
                                )
                            }

                            composable(
                                route = Screen.ArtistDetail.route,
                                arguments = listOf(navArgument("artistId") { type = NavType.StringType }),
                            ) { backStackEntry ->
                                val artistId = backStackEntry.arguments?.getString("artistId") ?: return@composable
                                ArtistDetailScreen(
                                    artistId = artistId,
                                    playbackViewModel = playbackViewModel,
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                )
                            }

                            composable(
                                route = Screen.PlaylistDetail.route,
                                arguments = listOf(navArgument("playlistId") { type = NavType.StringType }),
                            ) { backStackEntry ->
                                val playlistId = backStackEntry.arguments?.getString("playlistId") ?: return@composable
                                PlaylistDetailScreen(
                                    playlistId = playlistId,
                                    playbackViewModel = playbackViewModel,
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                    onNavigateToArtist = { artistId ->
                                        navController.navigate(Screen.ArtistDetail.createRoute(artistId))
                                    },
                                )
                            }

                            composable(Screen.Songs.route) {
                                SongsScreen(
                                    title = "Songs",
                                    favoritesOnly = false,
                                    playbackViewModel = playbackViewModel,
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                    onNavigateToArtist = { artistId ->
                                        navController.navigate(Screen.ArtistDetail.createRoute(artistId))
                                    },
                                )
                            }

                            composable(Screen.Favorites.route) {
                                SongsScreen(
                                    title = "Favorites",
                                    favoritesOnly = true,
                                    playbackViewModel = playbackViewModel,
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                    onNavigateToArtist = { artistId ->
                                        navController.navigate(Screen.ArtistDetail.createRoute(artistId))
                                    },
                                )
                            }

                            composable(Screen.Albums.route) {
                                AlbumsScreen(
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToAlbum = { albumId ->
                                        navController.navigate(Screen.AlbumDetail.createRoute(albumId))
                                    },
                                )
                            }

                            composable(Screen.Artists.route) {
                                ArtistsScreen(
                                    onBackClick = { navController.popBackStack() },
                                    onNavigateToArtist = { artistId ->
                                        navController.navigate(Screen.ArtistDetail.createRoute(artistId))
                                    },
                                )
                            }

                            composable(Screen.Settings.route) {
                                SettingsScreen(
                                    sessionViewModel = sessionViewModel,
                                    onBackClick = { navController.popBackStack() },
                                    onLoggedOut = {
                                        navController.popBackStack(Screen.Home.route, false)
                                    },
                                )
                            }
                        }

                        // Mini Player placed above bottom navigation
                        MiniPlayerBar(
                            viewModel = playbackViewModel,
                            modifier = Modifier.align(Alignment.BottomCenter),
                        )
                    }
                }

                // Fullscreen Player Overlay
                FullscreenPlayer(viewModel = playbackViewModel)
            }
        }
    }
}
