package github.realtvop.aonsoku.ui.navigation

import kotlinx.serialization.Serializable

/** Top-level destinations reachable from the floating navigation bar. */
enum class TopLevelTab { Home, Library, Search }

@Serializable
data object HomeRoute

@Serializable
data object LibraryRoute

@Serializable
data object SearchRoute

@Serializable
data object ArtistsRoute

/** Song list, optionally scoped to a search query or one artist. */
@Serializable
data class SongsRoute(
    val query: String? = null,
    val artistId: String? = null,
    val artistName: String? = null,
)

/** Album list; arguments mirror the web `?filter=` query parameters. */
@Serializable
data class AlbumsRoute(
    val filter: String? = null,
    val genre: String? = null,
    val artistId: String? = null,
    val artistName: String? = null,
    val query: String? = null,
    val yearFilter: String? = null,
)

@Serializable
data object FavoritesRoute

@Serializable
data object RadiosRoute

@Serializable
data class AlbumRoute(val id: String)

@Serializable
data class ArtistRoute(val id: String)

@Serializable
data class PlaylistRoute(val id: String)

/** Settings root when [page] is null, otherwise one settings category. */
@Serializable
data class SettingsRoute(val page: String? = null)
