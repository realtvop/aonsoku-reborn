package github.realtvop.aonsoku.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.ui.components.AlbumCard
import github.realtvop.aonsoku.ui.components.ArtistCard
import github.realtvop.aonsoku.ui.components.EmptyStateView
import github.realtvop.aonsoku.ui.components.SongListItem
import github.realtvop.aonsoku.ui.components.SongOption
import github.realtvop.aonsoku.viewmodel.PlaybackViewModel
import github.realtvop.aonsoku.viewmodel.SearchViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(
    searchViewModel: SearchViewModel,
    playbackViewModel: PlaybackViewModel,
    onNavigateToAlbum: (String) -> Unit,
    onNavigateToArtist: (String) -> Unit,
) {
    val query by searchViewModel.query.collectAsState()
    val artists by searchViewModel.artists.collectAsState()
    val albums by searchViewModel.albums.collectAsState()
    val songs by searchViewModel.songs.collectAsState()
    val isSearching by searchViewModel.isSearching.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { searchViewModel.onQueryChange(it) },
                        placeholder = { Text("Search songs, albums, artists...") },
                        leadingIcon = {
                            Icon(imageVector = Icons.Default.Search, contentDescription = null)
                        },
                        trailingIcon = {
                            if (query.isNotEmpty()) {
                                IconButton(onClick = { searchViewModel.clearQuery() }) {
                                    Icon(imageVector = Icons.Default.Clear, contentDescription = "Clear search")
                                }
                            }
                        },
                        singleLine = true,
                        shape = RoundedCornerShape(16.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(end = 8.dp),
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { paddingValues ->
        if (query.isBlank()) {
            EmptyStateView(
                icon = Icons.Default.Search,
                title = "Search your music",
                description = "Find artists, albums, and tracks in your library",
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
            )
        } else if (isSearching) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
        } else if (artists.isEmpty() && albums.isEmpty() && songs.isEmpty()) {
            EmptyStateView(
                icon = Icons.Default.Search,
                title = "No results found",
                description = "Try searching with a different term",
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
            )
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues)
                    .padding(bottom = 96.dp),
            ) {
                // Artists row
                if (artists.isNotEmpty()) {
                    item {
                        Text(
                            text = "Artists",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 8.dp),
                        )
                        LazyRow(
                            contentPadding = PaddingValues(horizontal = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            items(artists, key = { it.id }) { artist ->
                                ArtistCard(
                                    artist = artist,
                                    cardWidth = 110.dp,
                                    onClick = { onNavigateToArtist(artist.id) },
                                )
                            }
                        }
                    }
                }

                // Albums row
                if (albums.isNotEmpty()) {
                    item {
                        Text(
                            text = "Albums",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
                        )
                        LazyRow(
                            contentPadding = PaddingValues(horizontal = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            items(albums, key = { it.id }) { album ->
                                AlbumCard(
                                    album = album,
                                    cardWidth = 140.dp,
                                    onClick = { onNavigateToAlbum(album.id) },
                                )
                            }
                        }
                    }
                }

                // Songs list
                if (songs.isNotEmpty()) {
                    item {
                        Text(
                            text = "Songs",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
                        )
                    }
                    items(songs, key = { it.id }) { song ->
                        SongListItem(
                            song = song,
                            onSongClick = { playbackViewModel.playSong(song.id) },
                            onToggleFavorite = { playbackViewModel.toggleFavorite(song.id) },
                            onOptionSelected = { option ->
                                when (option) {
                                    SongOption.PlayNext -> playbackViewModel.addToQueueNext(listOf(song.id))
                                    SongOption.AddToQueue -> playbackViewModel.addToQueueLast(listOf(song.id))
                                    SongOption.GoToAlbum -> song.albumId?.let(onNavigateToAlbum)
                                    SongOption.GoToArtist -> song.artistId?.let(onNavigateToArtist)
                                }
                            },
                        )
                    }
                }
            }
        }
    }
}
