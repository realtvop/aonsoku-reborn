package github.realtvop.aonsoku.ui.screens

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.ui.components.AlbumCard
import github.realtvop.aonsoku.ui.components.AsyncCoverImage
import github.realtvop.aonsoku.ui.components.CoverType
import github.realtvop.aonsoku.viewmodel.HomeViewModel
import github.realtvop.aonsoku.viewmodel.PlaybackViewModel
import github.realtvop.aonsoku.viewmodel.SessionViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    homeViewModel: HomeViewModel,
    sessionViewModel: SessionViewModel,
    playbackViewModel: PlaybackViewModel,
    onNavigateToAlbum: (String) -> Unit,
    onNavigateToAlbums: () -> Unit,
    onNavigateToSettings: () -> Unit,
) {
    val syncState by sessionViewModel.syncState.collectAsState()
    val carouselAlbums by homeViewModel.carouselAlbums.collectAsState()
    val recentlyAdded by homeViewModel.recentlyAdded.collectAsState()
    val mostPlayed by homeViewModel.mostPlayed.collectAsState()
    val explore by homeViewModel.explore.collectAsState()
    val isLoading by homeViewModel.isLoading.collectAsState()

    val infiniteTransition = rememberInfiniteTransition(label = "sync_rotate")
    val syncRotation by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
        ),
        label = "sync_rotation",
    )

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Aonsoku",
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    )
                },
                actions = {
                    IconButton(onClick = { sessionViewModel.triggerSync() }) {
                        Icon(
                            imageVector = Icons.Default.Sync,
                            contentDescription = "Sync Library",
                            modifier = if (syncState.isSyncing) Modifier.rotate(syncRotation) else Modifier,
                            tint = if (syncState.isSyncing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }

                    IconButton(onClick = onNavigateToSettings) {
                        Icon(
                            imageVector = Icons.Default.AccountCircle,
                            contentDescription = "Settings",
                            modifier = Modifier.size(28.dp),
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { paddingValues ->
        PullToRefreshBox(
            isRefreshing = isLoading,
            onRefresh = { homeViewModel.refresh() },
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(bottom = 96.dp),
            ) {
                // Featured Album Banner (Carousel)
                val featuredAlbum = carouselAlbums.firstOrNull()
                if (featuredAlbum != null) {
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                            .clip(RoundedCornerShape(20.dp))
                            .clickable { onNavigateToAlbum(featuredAlbum.id) },
                        shape = RoundedCornerShape(20.dp),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                        ),
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            AsyncCoverImage(
                                coverArtId = featuredAlbum.coverArt ?: featuredAlbum.id,
                                type = CoverType.Album,
                                sizePx = 300,
                                modifier = Modifier
                                    .size(96.dp)
                                    .clip(RoundedCornerShape(14.dp)),
                                shape = RoundedCornerShape(14.dp),
                            )

                            Spacer(modifier = Modifier.width(16.dp))

                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = "FEATURED ALBUM",
                                    style = MaterialTheme.typography.labelSmall.copy(
                                        fontWeight = FontWeight.Bold,
                                        letterSpacing = 1.sp,
                                    ),
                                    color = MaterialTheme.colorScheme.primary,
                                )
                                Spacer(modifier = Modifier.height(2.dp))
                                Text(
                                    text = featuredAlbum.name,
                                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    text = featuredAlbum.artist,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }

                            FilledIconButton(
                                onClick = {
                                    playbackViewModel.playAlbum(featuredAlbum.id, index = 0, shuffle = false)
                                },
                                shape = CircleShape,
                                modifier = Modifier.size(44.dp),
                                colors = IconButtonDefaults.filledIconButtonColors(
                                    containerColor = MaterialTheme.colorScheme.primary,
                                ),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.PlayArrow,
                                    contentDescription = "Play Album",
                                    modifier = Modifier.size(24.dp),
                                )
                            }
                        }
                    }
                }

                // Recently Added
                if (recentlyAdded.isNotEmpty()) {
                    HomeSectionHeader(
                        title = "Recently Added",
                        onViewAllClick = onNavigateToAlbums,
                    )
                    AlbumRow(
                        albums = recentlyAdded,
                        onAlbumClick = onNavigateToAlbum,
                    )
                }

                // Most Played
                if (mostPlayed.isNotEmpty()) {
                    HomeSectionHeader(
                        title = "Most Played",
                        onViewAllClick = onNavigateToAlbums,
                    )
                    AlbumRow(
                        albums = mostPlayed,
                        onAlbumClick = onNavigateToAlbum,
                    )
                }

                // Explore (Random)
                if (explore.isNotEmpty()) {
                    HomeSectionHeader(
                        title = "Explore",
                        onViewAllClick = onNavigateToAlbums,
                    )
                    AlbumRow(
                        albums = explore,
                        onAlbumClick = onNavigateToAlbum,
                    )
                }
            }
        }
    }
}

@Composable
private fun HomeSectionHeader(
    title: String,
    onViewAllClick: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 8.dp, top = 16.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
        )
        if (onViewAllClick != null) {
            TextButton(onClick = onViewAllClick) {
                Text(text = "View all", style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun AlbumRow(
    albums: List<AlbumEntity>,
    onAlbumClick: (String) -> Unit,
) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(albums, key = { it.id }) { album ->
            AlbumCard(
                album = album,
                cardWidth = 140.dp,
                onClick = { onAlbumClick(album.id) },
            )
        }
    }
}
