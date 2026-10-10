package github.realtvop.aonsoku.ui

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.automirrored.outlined.PlaylistPlay
import androidx.compose.material.icons.automirrored.outlined.QueueMusic
import androidx.compose.material.icons.outlined.Album
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.CloudSync
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.LibraryMusic
import androidx.compose.material.icons.outlined.MusicNote
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Pause
import androidx.compose.material.icons.outlined.PlayArrow
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Repeat
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SkipNext
import androidx.compose.material.icons.outlined.SkipPrevious
import androidx.compose.material.icons.outlined.Shuffle
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.plugins.audio.AudioPlaybackSnapshot
import github.realtvop.aonsoku.plugins.audio.AudioQueueSnapshot
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity
import github.realtvop.aonsoku.plugins.data.db.entity.ArtistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.LyricsEntity
import github.realtvop.aonsoku.plugins.data.db.entity.PlaylistEntity
import github.realtvop.aonsoku.plugins.data.db.entity.SongEntity

private enum class NativeScreen {
    HOME,
    LIBRARY,
    SEARCH,
    SETTINGS,
    ALBUMS,
    ARTISTS,
    SONGS,
    FAVORITES,
    PLAYLISTS,
    ALBUM_DETAIL,
    ARTIST_DETAIL,
}

@Composable
fun AonsokuApp(viewModel: AonsokuViewModel) {
    val state by viewModel.state.collectAsState()

    AonsokuTheme {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            when {
                state.isLoading -> LoadingScreen()
                state.credentials == null -> LoginScreen(
                    isLoading = state.isLoggingIn,
                    error = state.loginError,
                    onLogin = viewModel::login,
                )
                else -> NativeShell(state = state, viewModel = viewModel)
            }
        }
    }
}

@Composable
private fun LoadingScreen() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
    }
}

@Composable
private fun LoginScreen(
    isLoading: Boolean,
    error: String?,
    onLogin: (String, String, String, String) -> Unit,
) {
    var url by rememberSaveable { mutableStateOf("") }
    var fallbackUrl by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(horizontal = 24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.widthIn(max = 460.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Aonsoku", style = MaterialTheme.typography.displaySmall)
            Text(
                "Your music, close to you.",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                "Connect to a Navidrome or Subsonic server to continue.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = url,
                onValueChange = { url = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Server URL") },
                leadingIcon = { Icon(Icons.Outlined.Wifi, null) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                singleLine = true,
            )
            OutlinedTextField(
                value = fallbackUrl,
                onValueChange = { fallbackUrl = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Fallback URL (optional)") },
                leadingIcon = { Icon(Icons.Outlined.AlternateEmail, null) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                singleLine = true,
            )
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Username") },
                singleLine = true,
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                modifier = Modifier.fillMaxWidth(),
                label = { Text("Password") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
            )
            if (error != null) {
                Text(error, color = MaterialTheme.colorScheme.error)
            }
            Button(
                onClick = { onLogin(url, fallbackUrl, username, password) },
                modifier = Modifier.fillMaxWidth(),
                enabled = !isLoading,
            ) {
                if (isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                    )
                } else {
                    Text("Connect")
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun NativeShell(state: NativeAppState, viewModel: AonsokuViewModel) {
    var screenName by rememberSaveable { mutableStateOf(NativeScreen.HOME.name) }
    var playerExpanded by rememberSaveable { mutableStateOf(false) }
    val screen = NativeScreen.valueOf(screenName)

    fun navigate(next: NativeScreen) {
        screenName = next.name
    }

    fun goBack() {
        if (playerExpanded) {
            playerExpanded = false
            return
        }
        screenName = when (screen) {
            NativeScreen.HOME -> NativeScreen.HOME
            NativeScreen.LIBRARY, NativeScreen.SEARCH -> NativeScreen.HOME
            else -> NativeScreen.LIBRARY
        }.name
    }

    fun openAlbum(album: AlbumEntity) {
        viewModel.loadAlbum(album.id)
        navigate(NativeScreen.ALBUM_DETAIL)
    }

    fun openArtist(artist: ArtistEntity) {
        viewModel.loadArtist(artist.id)
        navigate(NativeScreen.ARTIST_DETAIL)
    }

    BackHandler(enabled = playerExpanded || screen != NativeScreen.HOME) {
        goBack()
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            NativeTopBar(
                title = screenTitle(screen),
                showBack = screen != NativeScreen.HOME &&
                    screen != NativeScreen.LIBRARY &&
                    screen != NativeScreen.SEARCH,
                onBack = ::goBack,
                onSettings = { navigate(NativeScreen.SETTINGS) },
            )
            state.actionError?.let { message ->
                Card(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                ) {
                    Row(
                        modifier = Modifier.padding(start = 14.dp, end = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(message, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.onErrorContainer)
                        TextButton(onClick = viewModel::clearActionError) { Text("Dismiss") }
                    }
                }
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                when (screen) {
                    NativeScreen.HOME -> HomeScreen(
                        state = state,
                        viewModel = viewModel,
                        onAlbum = ::openAlbum,
                        onNavigate = ::navigate,
                        onOpenPlayer = { playerExpanded = true },
                    )
                    NativeScreen.LIBRARY -> LibraryScreen(
                        state = state,
                        onNavigate = ::navigate,
                    )
                    NativeScreen.SEARCH -> SearchScreen(
                        state = state,
                        viewModel = viewModel,
                        onAlbum = ::openAlbum,
                        onArtist = ::openArtist,
                        onSong = viewModel::playSong,
                    )
                    NativeScreen.SETTINGS -> SettingsScreen(state, viewModel)
                    NativeScreen.ALBUMS -> AlbumCollectionScreen(
                        state.albums,
                        onLoad = viewModel::loadAlbums,
                        onOpen = ::openAlbum,
                    )
                    NativeScreen.ARTISTS -> ArtistCollectionScreen(
                        state.artists,
                        onLoad = viewModel::loadArtists,
                        onOpen = ::openArtist,
                    )
                    NativeScreen.SONGS -> SongCollectionScreen(
                        title = "Songs",
                        songs = state.songs,
                        onLoad = viewModel::loadSongs,
                        viewModel = viewModel,
                    )
                    NativeScreen.FAVORITES -> SongCollectionScreen(
                        title = "Favorites",
                        songs = state.favoriteSongs,
                        onLoad = viewModel::loadFavorites,
                        viewModel = viewModel,
                    )
                    NativeScreen.PLAYLISTS -> PlaylistCollectionScreen(
                        state.playlists,
                        onLoad = viewModel::loadPlaylists,
                        onPlay = viewModel::playPlaylist,
                    )
                    NativeScreen.ALBUM_DETAIL -> AlbumDetailScreen(
                        album = state.selectedAlbum,
                        songs = state.selectedAlbumSongs,
                        viewModel = viewModel,
                        onArtist = { artistId ->
                            viewModel.loadArtist(artistId)
                            navigate(NativeScreen.ARTIST_DETAIL)
                        },
                    )
                    NativeScreen.ARTIST_DETAIL -> ArtistDetailScreen(
                        artist = state.selectedArtist,
                        albums = state.selectedArtistAlbums,
                        onAlbum = ::openAlbum,
                    )
                }
            }
        }

        if (screen != NativeScreen.SETTINGS) {
            state.queue.currentSong?.let { currentSong ->
                MiniPlayer(
                    song = currentSong,
                    playback = state.playback,
                    viewModel = viewModel,
                    onOpen = { playerExpanded = true },
                    onToggle = viewModel::togglePlayback,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .padding(bottom = 88.dp),
                )
            }
            FloatingNavigationBar(
                screen = screen,
                onNavigate = ::navigate,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }

        if (playerExpanded) {
            PlayerSheet(
                queue = state.queue,
                playback = state.playback,
                lyrics = state.lyrics,
                viewModel = viewModel,
                onDismiss = { playerExpanded = false },
            )
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
private fun NativeTopBar(
    title: String,
    showBack: Boolean,
    onBack: () -> Unit,
    onSettings: () -> Unit,
) {
    TopAppBar(
        title = { Text(title) },
        navigationIcon = {
            if (showBack) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
                }
            }
        },
        actions = {
            IconButton(onClick = onSettings) {
                Icon(Icons.Outlined.Settings, "Settings")
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.background,
        ),
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun FloatingNavigationBar(
    screen: NativeScreen,
    onNavigate: (NativeScreen) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .padding(horizontal = 16.dp)
            .navigationBarsPadding()
            .padding(bottom = 10.dp)
            .widthIn(max = 460.dp)
            .fillMaxWidth()
            .shadow(12.dp, RoundedCornerShape(30.dp)),
        shape = RoundedCornerShape(30.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
        tonalElevation = 4.dp,
    ) {
        NavigationBar(
            modifier = Modifier.clip(RoundedCornerShape(30.dp)),
            windowInsets = WindowInsets(0, 0, 0, 0),
        ) {
            NavigationBarItem(
                selected = screen == NativeScreen.HOME,
                onClick = { onNavigate(NativeScreen.HOME) },
                icon = { Icon(Icons.Outlined.Home, "Home") },
                label = { Text("Home") },
            )
            NavigationBarItem(
                selected = screen == NativeScreen.LIBRARY ||
                    screen == NativeScreen.ALBUMS ||
                    screen == NativeScreen.ARTISTS ||
                    screen == NativeScreen.SONGS ||
                    screen == NativeScreen.FAVORITES ||
                    screen == NativeScreen.PLAYLISTS,
                onClick = { onNavigate(NativeScreen.LIBRARY) },
                icon = { Icon(Icons.Outlined.LibraryMusic, "Library") },
                label = { Text("Library") },
            )
            NavigationBarItem(
                selected = screen == NativeScreen.SEARCH,
                onClick = { onNavigate(NativeScreen.SEARCH) },
                icon = { Icon(Icons.Outlined.Search, "Search") },
                label = { Text("Search") },
            )
        }
    }
}

@Composable
private fun HomeScreen(
    state: NativeAppState,
    viewModel: AonsokuViewModel,
    onAlbum: (AlbumEntity) -> Unit,
    onNavigate: (NativeScreen) -> Unit,
    onOpenPlayer: () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 132.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item {
            Text(
                text = "Listen in your flow",
                style = MaterialTheme.typography.headlineMedium,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        if (state.sync.isSyncing || state.needsInitialSync) {
            item {
                SyncCard(state, onSync = viewModel::refreshLibrary)
            }
        }
        state.queue.currentSong?.let { currentSong ->
            item {
                NowPlayingCard(
                    song = currentSong.title to currentSong.artist,
                    playback = state.playback,
                    onToggle = viewModel::togglePlayback,
                    onNext = viewModel::next,
                    onOpen = onOpenPlayer,
                )
            }
        }
        item {
            SectionTitle("Recently added")
        }
        item {
            if (state.homeAlbums.isEmpty()) {
                EmptyState(
                    icon = Icons.Outlined.CloudSync,
                    title = "Your library is ready when you are",
                    body = "Sync the server library to see albums here.",
                )
            } else {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(state.homeAlbums, key = { it.id }) { album ->
                        AlbumCard(viewModel, album, onClick = { onAlbum(album) })
                    }
                }
            }
        }
        item {
            SectionTitle("Quick actions")
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                QuickAction("Albums", Icons.Outlined.Album) { onNavigate(NativeScreen.ALBUMS) }
                QuickAction("Favorites", Icons.Outlined.Favorite) { onNavigate(NativeScreen.FAVORITES) }
                QuickAction("Playlists", Icons.AutoMirrored.Outlined.PlaylistPlay) { onNavigate(NativeScreen.PLAYLISTS) }
            }
        }
    }
}

@Composable
private fun SyncCard(state: NativeAppState, onSync: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.CloudSync, null)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text("Library sync", style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (state.sync.isSyncing) state.sync.phase.replace('-', ' ').replaceFirstChar { it.uppercase() }
                        else "Keep your offline library current",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                IconButton(onClick = onSync, enabled = !state.sync.isSyncing) {
                    Icon(Icons.Outlined.Refresh, "Sync now")
                }
            }
            if (state.sync.isSyncing) {
                LinearProgressIndicator(
                    progress = { (state.sync.progress / 100f).coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun NowPlayingCard(
    song: Pair<String, String>,
    playback: AudioPlaybackSnapshot,
    onToggle: () -> Unit,
    onNext: () -> Unit,
    onOpen: () -> Unit,
) {
    Card(
        modifier = Modifier.clickable(onClick = onOpen),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.MusicNote, null, Modifier.size(38.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(song.first, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                Text(song.second, style = MaterialTheme.typography.bodyMedium, maxLines = 1)
            }
            IconButton(onClick = onToggle) {
                Icon(
                    if (playback.isPlaying) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                    "Play or pause",
                )
            }
            IconButton(onClick = onNext) {
                Icon(Icons.Outlined.SkipNext, "Next")
            }
        }
    }
}

@Composable
private fun MiniPlayer(
    song: QueueSong,
    playback: AudioPlaybackSnapshot,
    viewModel: AonsokuViewModel,
    onOpen: () -> Unit,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .shadow(10.dp, RoundedCornerShape(20.dp))
            .clickable(onClick = onOpen),
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 5.dp,
    ) {
        Column {
            Row(
                modifier = Modifier.padding(start = 10.dp, top = 8.dp, end = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverArt(viewModel, song.coverArtId, Modifier.size(44.dp))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(song.title, style = MaterialTheme.typography.titleSmall, maxLines = 1)
                    Text(song.artist, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                IconButton(onClick = onToggle) {
                    Icon(
                        if (playback.isPlaying) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                        "Play or pause",
                    )
                }
            }
            if (playback.durationSeconds > 0.0) {
                LinearProgressIndicator(
                    progress = {
                        (playback.currentTimeSeconds / playback.durationSeconds).toFloat().coerceIn(0f, 1f)
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun PlayerSheet(
    queue: AudioQueueSnapshot,
    playback: AudioPlaybackSnapshot,
    lyrics: LyricsEntity?,
    viewModel: AonsokuViewModel,
    onDismiss: () -> Unit,
) {
    val currentSong = queue.currentSong ?: return
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var seekValue by remember(currentSong.id) {
        mutableStateOf(playback.currentTimeSeconds.toFloat())
    }
    var isSeeking by remember { mutableStateOf(false) }
    var lyricsVisible by remember(currentSong.id) { mutableStateOf(false) }
    LaunchedEffect(playback.songId, playback.currentTimeSeconds) {
        if (!isSeeking) seekValue = playback.currentTimeSeconds.toFloat()
    }

    ModalBottomSheet(sheetState = sheetState, onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Now playing", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(16.dp))
            CoverArt(viewModel, currentSong.coverArtId, Modifier.size(220.dp))
            Spacer(Modifier.height(16.dp))
            Text(currentSong.title, style = MaterialTheme.typography.headlineSmall, maxLines = 1)
            Text(currentSong.artist, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Slider(
                value = seekValue.coerceIn(0f, playback.durationSeconds.toFloat().coerceAtLeast(1f)),
                onValueChange = {
                    isSeeking = true
                    seekValue = it
                },
                onValueChangeFinished = {
                    isSeeking = false
                    viewModel.seek(seekValue.toDouble())
                },
                valueRange = 0f..playback.durationSeconds.toFloat().coerceAtLeast(1f),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(formatDuration(playback.currentTimeSeconds.toInt()), style = MaterialTheme.typography.labelMedium)
                Text(formatDuration(playback.durationSeconds.toInt()), style = MaterialTheme.typography.labelMedium)
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(22.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = viewModel::previous) {
                    Icon(Icons.Outlined.SkipPrevious, "Previous")
                }
                IconButton(onClick = viewModel::togglePlayback) {
                    Icon(
                        if (playback.isPlaying) Icons.Outlined.Pause else Icons.Outlined.PlayArrow,
                        "Play or pause",
                        Modifier.size(42.dp),
                    )
                }
                IconButton(onClick = viewModel::next) {
                    Icon(Icons.Outlined.SkipNext, "Next")
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = viewModel::toggleShuffle) {
                    Icon(Icons.Outlined.Shuffle, null)
                    Spacer(Modifier.width(4.dp))
                    Text(if (queue.isShuffleActive) "Shuffle on" else "Shuffle")
                }
                TextButton(onClick = viewModel::cycleRepeat) {
                    Icon(Icons.Outlined.Repeat, null)
                    Spacer(Modifier.width(4.dp))
                    Text("Repeat ${queue.repeatMode}")
                }
                TextButton(onClick = {
                    val shouldShow = !lyricsVisible
                    lyricsVisible = shouldShow
                    if (shouldShow) viewModel.loadLyrics(currentSong.id)
                }) {
                    Text("Lyrics")
                }
            }
            if (lyricsVisible) {
                Card(
                    modifier = Modifier.fillMaxWidth().height(180.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
                ) {
                    Text(
                        lyrics?.content ?: "No cached lyrics for this song.",
                        modifier = Modifier.padding(16.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.height(8.dp))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Outlined.QueueMusic, null)
                Spacer(Modifier.width(8.dp))
                Text("Queue", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                if (queue.userQueue.isNotEmpty()) {
                    TextButton(onClick = viewModel::clearUserQueue) { Text("Clear added") }
                }
            }
            LazyColumn(
                modifier = Modifier.fillMaxWidth().height(260.dp),
                contentPadding = PaddingValues(bottom = 20.dp),
            ) {
                itemsIndexed(queue.contextSongs, key = { index, song -> "context-$index-${song.id}" }) { index, song ->
                    QueueRow(
                        song = song,
                        isCurrent = !queue.isInUserQueue && queue.currentIndex == index,
                        onClick = { viewModel.playAtIndex(index) },
                    )
                }
                if (queue.userQueue.isNotEmpty()) {
                    item { Text("Added next", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(vertical = 8.dp)) }
                    items(queue.userQueue, key = { "user-${it.id}" }) { song ->
                        QueueRow(
                            song = song,
                            isCurrent = queue.isInUserQueue && queue.currentSong?.id == song.id,
                            onClick = {},
                            onRemove = { viewModel.removeFromQueue(song.id) },
                        )
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun QueueRow(
    song: QueueSong,
    isCurrent: Boolean,
    onClick: () -> Unit,
    onRemove: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(
                if (isCurrent) MaterialTheme.colorScheme.secondaryContainer
                else MaterialTheme.colorScheme.surface,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(song.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1)
            Text(song.artist, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        onRemove?.let {
            TextButton(onClick = it) { Text("Remove") }
        }
    }
}

@Composable
private fun LibraryScreen(state: NativeAppState, onNavigate: (NativeScreen) -> Unit) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item { Text("Browse your library", style = MaterialTheme.typography.titleLarge) }
        item { LibraryRow("Artists", "People and artists", Icons.Outlined.People) { onNavigate(NativeScreen.ARTISTS) } }
        item { LibraryRow("Songs", "Every track in your collection", Icons.Outlined.MusicNote) { onNavigate(NativeScreen.SONGS) } }
        item { LibraryRow("Albums", "Albums and releases", Icons.Outlined.Album) { onNavigate(NativeScreen.ALBUMS) } }
        item { LibraryRow("Favorites", "Your starred songs", Icons.Outlined.Favorite) { onNavigate(NativeScreen.FAVORITES) } }
        item { LibraryRow("Playlists", "Curated collections", Icons.AutoMirrored.Outlined.PlaylistPlay) { onNavigate(NativeScreen.PLAYLISTS) } }
        if (state.sync.isSyncing) {
            item { LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 12.dp)) }
        }
    }
}

@Composable
private fun LibraryRow(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Surface(
                modifier = Modifier.size(48.dp),
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.secondaryContainer,
            ) { Box(contentAlignment = Alignment.Center) { Icon(icon, null) } }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.Outlined.ChevronRight, "Open")
        }
    }
}

@Composable
private fun SearchScreen(
    state: NativeAppState,
    viewModel: AonsokuViewModel,
    onAlbum: (AlbumEntity) -> Unit,
    onArtist: (ArtistEntity) -> Unit,
    onSong: (String) -> Unit,
) {
    var query by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(
            value = query,
            onValueChange = { query = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            label = { Text("Search your library") },
            leadingIcon = { Icon(Icons.Outlined.Search, null) },
            trailingIcon = {
                TextButton(onClick = { viewModel.search(query) }) { Text("Search") }
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { viewModel.search(query) }),
            singleLine = true,
        )
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp, 4.dp, 16.dp, 132.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (state.searchArtists.isNotEmpty()) {
                item { SectionTitle("Artists") }
                items(state.searchArtists, key = { it.id }) { artist ->
                    SearchRow(
                        artist.name,
                        "${artist.albumCount} albums",
                        Icons.Outlined.People,
                        onClick = { onArtist(artist) },
                    )
                }
            }
            if (state.searchAlbums.isNotEmpty()) {
                item { SectionTitle("Albums") }
                items(state.searchAlbums, key = { it.id }) { album ->
                    SearchRow(album.name, album.artist, Icons.Outlined.Album) { onAlbum(album) }
                }
            }
            if (state.searchSongs.isNotEmpty()) {
                item { SectionTitle("Songs") }
                items(state.searchSongs, key = { it.id }) { song ->
                    SongRow(
                        song,
                        onClick = { onSong(song.id) },
                        onFavorite = { viewModel.toggleFavorite(song.id) },
                        onQueue = { viewModel.addSongToQueue(song.id) },
                    )
                }
            }
            if (query.isNotBlank() && state.searchArtists.isEmpty() && state.searchAlbums.isEmpty() && state.searchSongs.isEmpty()) {
                item { EmptyState(Icons.Outlined.Search, "No matches", "Try a different title, artist, or album.") }
            }
        }
    }
}

@Composable
private fun AlbumCollectionScreen(
    albums: List<AlbumEntity>,
    onLoad: () -> Unit,
    onOpen: (AlbumEntity) -> Unit,
) {
    LaunchedEffect(Unit) { onLoad() }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(albums, key = { it.id }) { album ->
            SearchRow(album.name, album.artist, Icons.Outlined.Album) { onOpen(album) }
        }
        if (albums.isEmpty()) {
            item { EmptyState(Icons.Outlined.Album, "No albums yet", "Sync your server library to populate albums.") }
        }
    }
}

@Composable
private fun ArtistCollectionScreen(
    artists: List<ArtistEntity>,
    onLoad: () -> Unit,
    onOpen: (ArtistEntity) -> Unit,
) {
    LaunchedEffect(Unit) { onLoad() }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(artists, key = { it.id }) { artist ->
            SearchRow(artist.name, "${artist.albumCount} albums", Icons.Outlined.People) { onOpen(artist) }
        }
        if (artists.isEmpty()) {
            item { EmptyState(Icons.Outlined.People, "No artists yet", "Sync your server library to populate artists.") }
        }
    }
}

@Composable
private fun SongCollectionScreen(
    title: String,
    songs: List<SongEntity>,
    onLoad: () -> Unit,
    viewModel: AonsokuViewModel,
) {
    LaunchedEffect(Unit) { onLoad() }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        itemsIndexed(songs, key = { _, song -> song.id }) { _, song ->
            SongRow(
                song,
                onClick = { viewModel.playSong(song.id) },
                onFavorite = { viewModel.toggleFavorite(song.id) },
                onQueue = { viewModel.addSongToQueue(song.id) },
            )
        }
        if (songs.isEmpty()) {
            item { EmptyState(Icons.Outlined.MusicNote, "No $title yet", "Sync your server library to populate this list.") }
        }
    }
}

@Composable
private fun PlaylistCollectionScreen(
    playlists: List<PlaylistEntity>,
    onLoad: () -> Unit,
    onPlay: (String) -> Unit,
) {
    LaunchedEffect(Unit) { onLoad() }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(playlists, key = { it.id }) { playlist ->
            SearchRow(
                playlist.name,
                "${playlist.songCount} songs",
                Icons.AutoMirrored.Outlined.PlaylistPlay,
                onClick = { onPlay(playlist.id) },
            )
        }
        if (playlists.isEmpty()) {
            item {
                EmptyState(
                    Icons.AutoMirrored.Outlined.PlaylistPlay,
                    "No playlists yet",
                    "Playlists from the server will appear here.",
                )
            }
        }
    }
}

@Composable
private fun AlbumDetailScreen(
    album: AlbumEntity?,
    songs: List<SongEntity>,
    viewModel: AonsokuViewModel,
    onArtist: (String) -> Unit,
) {
    if (album == null) {
        LoadingScreen()
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CoverArt(viewModel, album.coverArt, Modifier.size(132.dp))
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(album.name, style = MaterialTheme.typography.headlineSmall)
                    Text(
                        album.artist,
                        modifier = Modifier.clickable { album.artistId?.let(onArtist) },
                        color = MaterialTheme.colorScheme.primary,
                    )
                    album.year?.let { Text(it.toString(), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        }
        item {
            Button(onClick = { viewModel.playAlbum(album.id) }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.PlayArrow, null)
                Spacer(Modifier.width(8.dp))
                Text("Play album")
            }
        }
        itemsIndexed(songs, key = { _, song -> song.id }) { index, song ->
            SongRow(
                song,
                number = index + 1,
                onClick = { viewModel.playSong(song.id) },
                onFavorite = { viewModel.toggleFavorite(song.id) },
                onQueue = { viewModel.addSongToQueue(song.id) },
            )
        }
    }
}

@Composable
private fun ArtistDetailScreen(
    artist: ArtistEntity?,
    albums: List<AlbumEntity>,
    onAlbum: (AlbumEntity) -> Unit,
) {
    if (artist == null) {
        LoadingScreen()
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 132.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        item {
            Text(artist.name, style = MaterialTheme.typography.headlineSmall)
            Text("${artist.albumCount} albums", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        items(albums, key = { it.id }) { album ->
            SearchRow(album.name, album.year?.toString() ?: "Album", Icons.Outlined.Album) { onAlbum(album) }
        }
    }
}

@Composable
private fun SettingsScreen(state: NativeAppState, viewModel: AonsokuViewModel) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp, 8.dp, 16.dp, 32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            SettingsCard(
                icon = Icons.Outlined.Wifi,
                title = "Server",
                body = state.credentials?.serverUrl ?: "Not connected",
            )
        }
        item {
            SettingsCard(
                icon = Icons.Outlined.Storage,
                title = "Native library",
                body = if (state.sync.isSyncing) "Syncing ${state.sync.progress}%" else "Room database and image cache",
            )
        }
        item {
            OutlinedButton(
                onClick = viewModel::refreshLibrary,
                modifier = Modifier.fillMaxWidth(),
                enabled = !state.sync.isSyncing,
            ) {
                Icon(Icons.Outlined.Refresh, null)
                Spacer(Modifier.width(8.dp))
                Text("Sync library")
            }
        }
        item {
            OutlinedButton(onClick = viewModel::logout, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.AutoMirrored.Outlined.Logout, null)
                Spacer(Modifier.width(8.dp))
                Text("Sign out")
            }
        }
        item {
            Text(
                "Aonsoku native Android",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 16.dp),
            )
        }
    }
}

@Composable
private fun SettingsCard(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, body: String) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(28.dp))
            Spacer(Modifier.width(14.dp))
            Column {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun SearchRow(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Row(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                Text(subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            Icon(Icons.Outlined.ChevronRight, "Open", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SongRow(
    song: SongEntity,
    onClick: () -> Unit,
    onFavorite: () -> Unit,
    onQueue: (() -> Unit)? = null,
    number: Int? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (number != null) {
            Text(number.toString(), Modifier.width(28.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            Icon(Icons.Outlined.MusicNote, null, Modifier.size(28.dp), tint = MaterialTheme.colorScheme.primary)
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(song.title, style = MaterialTheme.typography.titleMedium, maxLines = 1)
            Text(
                listOfNotNull(song.artist, song.album).joinToString(" • "),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        Text(formatDuration(song.duration), color = MaterialTheme.colorScheme.onSurfaceVariant)
        onQueue?.let {
            IconButton(onClick = it) {
                Icon(Icons.AutoMirrored.Outlined.QueueMusic, "Add to queue")
            }
        }
        IconButton(onClick = onFavorite) {
            Icon(
                if (song.starredAt != null) Icons.Outlined.Favorite else Icons.Outlined.FavoriteBorder,
                "Favorite",
                tint = if (song.starredAt != null) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun AlbumCard(viewModel: AonsokuViewModel, album: AlbumEntity, onClick: () -> Unit) {
    Column(modifier = Modifier.width(148.dp).clickable(onClick = onClick)) {
        CoverArt(viewModel, album.coverArt, Modifier.size(148.dp))
        Spacer(Modifier.height(8.dp))
        Text(album.name, style = MaterialTheme.typography.titleSmall, maxLines = 1)
        Text(album.artist, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
    }
}

@Composable
private fun CoverArt(viewModel: AonsokuViewModel?, coverArtId: String?, modifier: Modifier) {
    var path by rememberSaveable(coverArtId) { mutableStateOf<String?>(null) }
    LaunchedEffect(viewModel, coverArtId) {
        if (viewModel != null && !coverArtId.isNullOrBlank()) {
            path = viewModel.coverFile(coverArtId)
        }
    }
    Surface(
        modifier = modifier.clip(RoundedCornerShape(20.dp)),
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
    ) {
        if (path != null) {
            val bitmap = BitmapFactory.decodeFile(path)
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } else {
                Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.Album, null, Modifier.size(42.dp)) }
            }
        } else {
            Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.Album, null, Modifier.size(42.dp)) }
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(top = 4.dp))
}

@Composable
private fun QuickAction(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, contentPadding = PaddingValues(horizontal = 12.dp)) {
        Icon(icon, null, Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(title)
    }
}

@Composable
private fun EmptyState(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, body: String) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, null, Modifier.size(44.dp), tint = MaterialTheme.colorScheme.primary)
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun screenTitle(screen: NativeScreen): String = when (screen) {
    NativeScreen.HOME -> "Home"
    NativeScreen.LIBRARY -> "Library"
    NativeScreen.SEARCH -> "Search"
    NativeScreen.SETTINGS -> "Settings"
    NativeScreen.ALBUMS -> "Albums"
    NativeScreen.ARTISTS -> "Artists"
    NativeScreen.SONGS -> "Songs"
    NativeScreen.FAVORITES -> "Favorites"
    NativeScreen.PLAYLISTS -> "Playlists"
    NativeScreen.ALBUM_DETAIL -> "Album"
    NativeScreen.ARTIST_DETAIL -> "Artist"
}

private fun formatDuration(seconds: Int): String {
    val minutes = seconds / 60
    val remainder = seconds % 60
    return "%d:%02d".format(minutes, remainder)
}
