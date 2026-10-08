package github.realtvop.aonsoku.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistDetailEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity
import github.realtvop.aonsoku.ui.components.AsyncCoverImage
import github.realtvop.aonsoku.ui.components.CoverType
import github.realtvop.aonsoku.ui.components.SongListItem
import github.realtvop.aonsoku.ui.components.SongOption
import github.realtvop.aonsoku.utils.TimeUtils
import github.realtvop.aonsoku.viewmodel.PlaybackViewModel
import org.json.JSONArray

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlaylistDetailScreen(
    playlistId: String,
    playbackViewModel: PlaybackViewModel,
    onBackClick: () -> Unit,
    onNavigateToAlbum: (String) -> Unit,
    onNavigateToArtist: (String) -> Unit,
) {
    val context = LocalContext.current
    var playlistDetail by remember { mutableStateOf<PlaylistDetailEntity?>(null) }
    var songs by remember { mutableStateOf<List<SongEntity>>(emptyList()) }
    var isLoading by remember { mutableStateOf(true) }

    LaunchedEffect(playlistId) {
        val library = AppServices.getInstance(context).library
        val detail = library.getPlaylist(playlistId)
        playlistDetail = detail

        if (detail != null) {
            val parsedSongs = mutableListOf<SongEntity>()
            try {
                val array = JSONArray(detail.entriesJson)
                for (i in 0 until array.length()) {
                    val obj = array.getJSONObject(i)
                    parsedSongs.add(
                        SongEntity(
                            id = obj.optString("id", ""),
                            title = obj.optString("title", "Unknown"),
                            artist = if (obj.has("artist") && !obj.isNull("artist")) obj.getString("artist") else null,
                            album = if (obj.has("album") && !obj.isNull("album")) obj.getString("album") else null,
                            albumId = if (obj.has("albumId") && !obj.isNull("albumId")) obj.getString("albumId") else null,
                            artistId = if (obj.has("artistId") && !obj.isNull("artistId")) obj.getString("artistId") else null,
                            coverArt = if (obj.has("coverArt") && !obj.isNull("coverArt")) obj.getString("coverArt") else null,
                            duration = obj.optInt("duration", 0),
                            track = obj.optInt("track", i + 1),
                        )
                    )
                }
            } catch (_: Exception) {}
            songs = parsedSongs
        }
        isLoading = false
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {},
                navigationIcon = {
                    IconButton(onClick = onBackClick) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
    ) { paddingValues ->
        if (isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
            return@Scaffold
        }

        val detail = playlistDetail
        if (detail == null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
                contentAlignment = Alignment.Center,
            ) {
                Text("Playlist not found", style = MaterialTheme.typography.bodyLarge)
            }
            return@Scaffold
        }

        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(bottom = 96.dp),
        ) {
            item {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    AsyncCoverImage(
                        coverArtId = detail.coverArt ?: detail.id,
                        type = CoverType.Album,
                        sizePx = 500,
                        modifier = Modifier
                            .size(180.dp)
                            .aspectRatio(1f)
                            .clip(RoundedCornerShape(20.dp)),
                        shape = RoundedCornerShape(20.dp),
                    )

                    Spacer(modifier = Modifier.height(16.dp))

                    Text(
                        text = detail.name,
                        style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )

                    val meta = "${songs.size} tracks • ${TimeUtils.formatDuration(detail.duration)}"
                    Text(
                        text = meta,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )

                    Spacer(modifier = Modifier.height(16.dp))

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Button(
                            onClick = {
                                playbackViewModel.playPlaylist(detail.id, index = 0, shuffle = false)
                            },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(14.dp),
                        ) {
                            Icon(imageVector = Icons.Default.PlayArrow, contentDescription = null)
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Play", fontWeight = FontWeight.Bold)
                        }

                        FilledTonalButton(
                            onClick = {
                                playbackViewModel.playPlaylist(detail.id, index = 0, shuffle = true)
                            },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(14.dp),
                        ) {
                            Icon(imageVector = Icons.Default.Shuffle, contentDescription = null)
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Shuffle", fontWeight = FontWeight.Bold)
                        }
                    }

                    Spacer(modifier = Modifier.height(16.dp))
                }
            }

            itemsIndexed(songs, key = { index, song -> "${song.id}_$index" }) { index, song ->
                SongListItem(
                    song = song,
                    trackNumber = index + 1,
                    showCover = true,
                    onSongClick = {
                        playbackViewModel.playPlaylist(detail.id, index = index, shuffle = false)
                    },
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
