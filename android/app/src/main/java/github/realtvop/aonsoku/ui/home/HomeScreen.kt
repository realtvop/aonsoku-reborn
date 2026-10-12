package github.realtvop.aonsoku.ui.home

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.AlbumFilters
import github.realtvop.aonsoku.data.HomeSection
import github.realtvop.aonsoku.data.PinnedEntry
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.plural
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.AlbumRowSection
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.MediaCard
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.PreviewCardWidth
import github.realtvop.aonsoku.ui.components.RootHeader
import github.realtvop.aonsoku.ui.components.SectionHeader
import github.realtvop.aonsoku.ui.components.graphViewModel
import github.realtvop.aonsoku.ui.components.humanDuration
import github.realtvop.aonsoku.ui.navigation.AlbumRoute
import github.realtvop.aonsoku.ui.navigation.AlbumsRoute
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.PlaylistRoute
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import github.realtvop.aonsoku.ui.shell.floatingBarsContentPadding
import kotlinx.coroutines.delay

private const val CAROUSEL_INTERVAL_MS = 10_000L

@Composable
fun HomeScreen() {
    val model = graphViewModel { HomeViewModel(it) }
    val state by model.state.collectAsStateWithLifecycle()
    val navigator = LocalNavigator.current
    val overlays = LocalOverlays.current
    val online by LocalAppGraph.current.network.isOnline.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val refreshState = rememberPullToRefreshState()

    Column(modifier = Modifier.fillMaxSize()) {
        RootHeader(title = t("sidebar.home"))
        PullToRefreshBox(
            isRefreshing = state.refreshing,
            onRefresh = model::refresh,
            modifier = Modifier.fillMaxSize(),
            state = refreshState,
            indicator = {
                PullToRefreshDefaults.LoadingIndicator(
                    state = refreshState,
                    isRefreshing = state.refreshing,
                    modifier = Modifier.align(Alignment.TopCenter),
                )
            },
        ) {
            when {
                state.loading -> PageLoading()
                else -> LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = floatingBarsContentPadding(),
                ) {
                    if (state.isEmpty) {
                        item(key = "empty") {
                            EmptyState(
                                title = t(if (online) "album.list.empty.title" else "offline.mode"),
                                description = t(
                                    if (online) "album.list.empty.info" else "offline.disconnected",
                                ),
                                icon = if (online) {
                                    Icons.Rounded.LibraryMusic
                                } else {
                                    Icons.Rounded.CloudOff
                                },
                                modifier = Modifier.fillParentMaxHeight(0.7f),
                            )
                        }
                    }
                    if (state.carousel.isNotEmpty()) {
                        item(key = "carousel") {
                            HomeCarousel(
                                albums = state.carousel,
                                onAlbum = { navigator.open(AlbumRoute(it.id)) },
                            )
                        }
                    }
                    if (state.pinned.isNotEmpty()) {
                        item(key = "pinned") {
                            PinnedSection(
                                entries = state.pinned,
                                onOpen = { entry ->
                                    navigator.open(
                                        when (entry) {
                                            is PinnedEntry.PinnedAlbum -> AlbumRoute(entry.album.id)
                                            is PinnedEntry.PinnedPlaylist ->
                                                PlaylistRoute(entry.playlist.id)
                                        },
                                    )
                                },
                                onMenu = { entry ->
                                    overlays.show(
                                        when (entry) {
                                            is PinnedEntry.PinnedAlbum ->
                                                Overlay.AlbumMenu(entry.album)
                                            is PinnedEntry.PinnedPlaylist ->
                                                Overlay.PlaylistMenu(entry.playlist, showPlay = true)
                                        },
                                    )
                                },
                            )
                        }
                    }
                    items(HomeSection.entries, key = { it.name }) { section ->
                        val albums = state.sections[section].orEmpty()
                        if (albums.isNotEmpty()) {
                            AlbumRowSection(
                                title = t(section.titleKey),
                                albums = albums,
                                onAlbum = { navigator.open(AlbumRoute(it.id)) },
                                onAlbumMenu = { overlays.show(Overlay.AlbumMenu(it)) },
                                moreLabel = t("generic.seeMore"),
                                onMore = { navigator.open(AlbumsRoute(filter = section.filter)) },
                            )
                        }
                    }
                }
            }
        }
    }
}

private val HomeSection.titleKey: String
    get() = when (this) {
        HomeSection.RecentlyPlayed -> "home.recentlyPlayed"
        HomeSection.MostPlayed -> "home.mostPlayed"
        HomeSection.RecentlyAdded -> "home.recentlyAdded"
        HomeSection.Explore -> "home.explore"
    }

private val HomeSection.filter: String
    get() = when (this) {
        HomeSection.RecentlyPlayed -> AlbumFilters.RECENTLY_PLAYED
        HomeSection.MostPlayed -> AlbumFilters.MOST_PLAYED
        HomeSection.RecentlyAdded -> AlbumFilters.RECENTLY_ADDED
        HomeSection.Explore -> AlbumFilters.RANDOM
    }

/** Auto-advancing banner of random albums at the top of the home page. */
@Composable
private fun HomeCarousel(albums: List<Album>, onAlbum: (Album) -> Unit) {
    val looping = albums.size > 1
    val initialPage = remember(albums.size) {
        if (looping) (Int.MAX_VALUE / 2).let { it - it % albums.size } else 0
    }
    val pagerState = rememberPagerState(initialPage = initialPage) {
        if (looping) Int.MAX_VALUE else albums.size
    }

    LaunchedEffect(pagerState, albums.size) {
        if (!looping) return@LaunchedEffect
        while (true) {
            delay(CAROUSEL_INTERVAL_MS)
            if (!pagerState.isScrollInProgress) {
                runCatching { pagerState.animateScrollToPage(pagerState.currentPage + 1) }
            }
        }
    }

    Column(modifier = Modifier.fillMaxWidth().padding(top = 4.dp)) {
        HorizontalPager(
            state = pagerState,
            contentPadding = PaddingValues(horizontal = 20.dp),
            pageSpacing = 12.dp,
            key = { it },
        ) { page ->
            val album = albums[page % albums.size]
            CarouselCard(album = album, onClick = { onAlbum(album) })
        }
        if (looping) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                horizontalArrangement = Arrangement.Center,
            ) {
                val current = pagerState.currentPage % albums.size
                repeat(albums.size) { index ->
                    Box(
                        modifier = Modifier
                            .padding(horizontal = 3.dp)
                            .size(width = if (index == current) 16.dp else 6.dp, height = 6.dp)
                            .clip(CircleShape)
                            .background(
                                if (index == current) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.outlineVariant
                                },
                            ),
                    )
                }
            }
        }
    }
}

@Composable
private fun CarouselCard(album: Album, onClick: () -> Unit) {
    val art = remember(album.id, album.coverArt) { CoverArt(album.coverArt ?: album.id) }
    val background = MaterialTheme.colorScheme.background
    // Blur needs Android 12; older versions get a denser scrim instead.
    val canBlur = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    val scrim = if (canBlur) listOf(0.40f, 0.80f) else listOf(0.72f, 0.92f)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(148.dp)
            .clip(MaterialTheme.shapes.extraLarge)
            .background(MaterialTheme.colorScheme.surfaceContainerHigh)
            .clickable(onClick = onClick),
    ) {
        CoverImage(
            art = art,
            modifier = Modifier.matchParentSize().blur(36.dp),
            shape = RectangleShape,
        )
        Box(
            modifier = Modifier
                .matchParentSize()
                .background(
                    Brush.verticalGradient(scrim.map { background.copy(alpha = it) }),
                ),
        )
        Row(modifier = Modifier.fillMaxSize().padding(14.dp)) {
            CoverImage(
                art = art,
                modifier = Modifier.fillMaxHeight().aspectRatio(1f),
                shape = MaterialTheme.shapes.large,
                contentDescription = album.name,
            )
            Spacer(Modifier.width(14.dp))
            Column(
                modifier = Modifier.weight(1f).fillMaxHeight(),
                verticalArrangement = Arrangement.Bottom,
            ) {
                Text(
                    text = album.name,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onBackground,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = album.artistLabel,
                    style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun PinnedSection(
    entries: List<PinnedEntry>,
    onOpen: (PinnedEntry) -> Unit,
    onMenu: (PinnedEntry) -> Unit,
) {
    val strings = LocalStrings.current
    Column(modifier = Modifier.fillMaxWidth()) {
        SectionHeader(title = t("home.pinned"))
        LazyRow(
            contentPadding = PaddingValues(horizontal = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(
                items = entries.take(16),
                key = {
                    when (it) {
                        is PinnedEntry.PinnedAlbum -> "album-${it.album.id}"
                        is PinnedEntry.PinnedPlaylist -> "playlist-${it.playlist.id}"
                    }
                },
            ) { entry ->
                when (entry) {
                    is PinnedEntry.PinnedAlbum -> MediaCard(
                        art = CoverArt(entry.album.coverArt ?: entry.album.id),
                        title = entry.album.name,
                        subtitle = entry.album.artistLabel,
                        onClick = { onOpen(entry) },
                        onLongClick = { onMenu(entry) },
                        modifier = Modifier.width(PreviewCardWidth),
                    )
                    is PinnedEntry.PinnedPlaylist -> {
                        val playlist = entry.playlist
                        val details = buildList {
                            add(t("playlist.headline"))
                            if (playlist.songCount > 0) {
                                add(plural("playlist.songCount", playlist.songCount))
                            }
                            if (playlist.duration > 0) {
                                add(
                                    t(
                                        "playlist.duration",
                                        "duration" to strings.humanDuration(playlist.duration),
                                    ),
                                )
                            }
                        }
                        MediaCard(
                            art = CoverArt(playlist.coverArt?.takeIf { playlist.songCount > 0 }),
                            title = playlist.name,
                            subtitle = details.joinToString(" / "),
                            onClick = { onOpen(entry) },
                            onLongClick = { onMenu(entry) },
                            modifier = Modifier.width(PreviewCardWidth),
                            kind = CoverKind.Playlist,
                        )
                    }
                }
            }
        }
    }
}
