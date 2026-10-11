@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.material3.ExperimentalMaterial3ExpressiveApi::class)
package github.realtvop.aonsoku.ui

import android.graphics.BitmapFactory
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.plugins.audio.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun AonsokuApp(model: AonsokuViewModel) {
    val preferences by model.preferences.collectAsStateWithLifecycle()
    val systemDark = isSystemInDarkTheme()
    val dark = when (model.preference("theme_store.themeMode")) { "light" -> false; "dark" -> true; else -> systemDark }
    val context = LocalContext.current
    val colors = if (Build.VERSION.SDK_INT >= 31 && model.booleanPreference("theme_store.materialYouEnabled", true)) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else if (dark) darkColorScheme(primary = Color(0xffc6bfff), secondary = Color(0xffb6c4ff))
    else lightColorScheme(primary = Color(0xff6554c0), secondary = Color(0xff545e86))
    MaterialExpressiveTheme(colorScheme = colors) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            val signedIn by model.signedIn.collectAsStateWithLifecycle()
            if (signedIn) NativeShell(model) else LoginScreen(model)
        }
    }
}

@Composable
private fun LoginScreen(model: AonsokuViewModel) {
    var url by rememberSaveable { mutableStateOf("") }
    var fallback by rememberSaveable { mutableStateOf("") }
    var user by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(model) { model.messages.collect { busy = false; snackbar.showSnackbar(it) } }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }) { padding ->
        Column(Modifier.padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(28.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Spacer(Modifier.height(40.dp))
            Icon(Icons.Default.GraphicEq, null, Modifier.size(64.dp), tint = MaterialTheme.colorScheme.primary)
            Text("Aonsoku", style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
            Text("Your music, everywhere", style = MaterialTheme.typography.titleLarge)
            Text("Connect to your Navidrome or Subsonic server", color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(url, { url = it }, label = { Text("Server URL") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(fallback, { fallback = it }, label = { Text("Fallback URL (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(user, { user = it }, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            Button({ busy = true; model.login(url, fallback, user, password) { busy = false } }, enabled = !busy && url.isNotBlank() && user.isNotBlank(), modifier = Modifier.fillMaxWidth().height(56.dp)) {
                if (busy) CircularProgressIndicator(Modifier.size(24.dp)) else Text("Sign in")
            }
        }
    }
}

@Composable
private fun NativeShell(model: AonsokuViewModel) {
    val page by model.page.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val queue by model.queue.collectAsStateWithLifecycle()
    val sync by model.sync.collectAsStateWithLifecycle()
    var playerOpen by rememberSaveable { mutableStateOf(false) }
    var menuItem by remember { mutableStateOf<LibraryItem?>(null) }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(model) { model.messages.collect { snackbar.showSnackbar(it) } }
    BackHandler { if (playerOpen) playerOpen = false else if (!model.back()) model.root("home", "Home") }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(page.title, fontWeight = FontWeight.Bold) }, navigationIcon = {
                if (page.route !in listOf("home", "library", "search")) IconButton({ model.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            }, actions = {
                IconButton({ model.services.library.syncIncremental() }) { Icon(Icons.Default.Sync, "Refresh library") }
                IconButton({ model.navigate("settings", "Settings") }) { Icon(Icons.Default.AccountCircle, "Settings and account") }
            })
        },
        bottomBar = {
            Column(Modifier.navigationBarsPadding().padding(horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (queue.currentSong != null) {
                    Surface(onClick = { playerOpen = true }, shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp)) {
                        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Cover(model, queue.currentSong?.coverArtId, Modifier.size(48.dp))
                            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) { Text(queue.currentSong?.title.orEmpty(), maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold); Text(queue.currentSong?.artist.orEmpty(), maxLines = 1, style = MaterialTheme.typography.bodySmall) }
                            IconButton({ model.command(AudioCommand.TogglePlayPause) }) { Icon(if (playback.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, if (playback.isPlaying) "Pause" else "Play") }
                            IconButton({ model.command(AudioCommand.Next) }) { Icon(Icons.Default.SkipNext, "Next") }
                        }
                    }
                }
                Surface(shape = CircleShape, tonalElevation = 6.dp, shadowElevation = 5.dp, color = MaterialTheme.colorScheme.surfaceContainerHigh, modifier = Modifier.widthIn(max = 430.dp).padding(bottom = 12.dp)) {
                    Row(Modifier.padding(6.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        NavButton("Home", Icons.Default.Home, page.route == "home") { model.root("home", "Home") }
                        NavButton("Library", Icons.Default.LibraryMusic, page.route !in listOf("home", "search", "settings")) { model.root("library", "Library") }
                        NavButton("Search", Icons.Default.Search, page.route == "search") { model.root("search", "Search") }
                    }
                }
            }
        }, snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (sync.isSyncing) { LinearProgressIndicator(progress = { sync.progress / 100f }, modifier = Modifier.fillMaxWidth()); Text("Syncing ${sync.tier.orEmpty()} · ${sync.processedItems} / ${sync.totalItems}", Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.labelSmall) }
            when (page.route) {
                "home" -> HomeScreen(model)
                "library" -> LibraryScreen(model)
                "settings" -> Text("Native settings", Modifier.padding(24.dp))
                else -> CollectionScreen(model, page, { menuItem = it })
            }
        }
    }
    if (playerOpen) PlayerSheet(model) { playerOpen = false }
    menuItem?.let { item ->
        ModalBottomSheet({ menuItem = null }) {
            Text(item.title, Modifier.padding(24.dp), style = MaterialTheme.typography.headlineSmall)
            ActionRow("Play", Icons.Default.PlayArrow) { model.open(item); menuItem = null }
            if (item.kind == "song") {
                ActionRow("Play next", Icons.Default.PlaylistPlay) { model.command(AudioCommand.AddSongsById(listOf(item.id), "next")); menuItem = null }
                ActionRow("Add to queue", Icons.AutoMirrored.Filled.PlaylistAdd) { model.command(AudioCommand.AddSongsById(listOf(item.id), "last")); menuItem = null }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun RowScope.NavButton(label: String, icon: ImageVector, selected: Boolean, click: () -> Unit) {
    Surface(onClick = click, color = if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent, shape = CircleShape, modifier = Modifier.weight(1f)) {
        Column(Modifier.padding(vertical = 10.dp, horizontal = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) { Icon(icon, label); Text(label, style = MaterialTheme.typography.labelMedium) }
    }
}
@Composable
fun ActionRow(label: String, icon: ImageVector = Icons.Default.ChevronRight, click: () -> Unit) {
    ListItem(headlineContent = { Text(label) }, leadingContent = { Icon(icon, null) }, modifier = Modifier.clickable(onClick = click))
}
@Composable
fun Cover(model: AonsokuViewModel, id: String?, modifier: Modifier = Modifier) {
    val bitmap by produceState<android.graphics.Bitmap?>(null, id) {
        value = withContext(Dispatchers.IO) { runCatching { id?.let { model.services.library.resolveCoverImage(it) ?: model.services.library.downloadCoverImage(it, "300") }?.file?.let { BitmapFactory.decodeFile(it.path) } }.getOrNull() }
    }
    Box(modifier.clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surfaceContainerHighest), contentAlignment = Alignment.Center) {
        if (bitmap != null) Image(bitmap!!.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Icon(Icons.Default.MusicNote, null, tint = MaterialTheme.colorScheme.primary)
    }
}
@Composable
private fun HomeScreen(model: AonsokuViewModel) {
    val sections by model.home.collectAsStateWithLifecycle()
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        item {
            Card(Modifier.padding(horizontal = 20.dp).fillMaxWidth(), shape = RoundedCornerShape(32.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                Column(Modifier.padding(24.dp)) { Text("Made for your listening", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold); Text("Rediscover your library", Modifier.padding(top = 8.dp)); Button({ model.navigate("albums", "Explore"); model.filter(sort = "random") }, Modifier.padding(top = 16.dp)) { Icon(Icons.Default.Shuffle, null); Spacer(Modifier.width(8.dp)); Text("Explore albums") } }
            }
        }
        sections.forEach { section ->
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) { Text(section.title, Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold); TextButton({ model.navigate("albums", section.title); model.filter(sort = section.sort) }) { Text("See all") } }
                LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(section.items, key = { it.id }) { item -> Column(Modifier.width(144.dp).clickable { model.open(item) }) { Cover(model, item.cover, Modifier.size(144.dp)); Text(item.title, Modifier.padding(top = 8.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold); Text(item.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
                }
            }
        }
    }
}
@Composable
private fun LibraryScreen(model: AonsokuViewModel) {
    val page by model.page.collectAsStateWithLifecycle()
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { listOf(Triple("artists", "Artists", Icons.Default.Mic), Triple("songs", "Songs", Icons.Default.MusicNote), Triple("albums", "Albums", Icons.Default.Album), Triple("favorites", "Favorites", Icons.Default.Favorite), Triple("playlists", "Playlists", Icons.AutoMirrored.Filled.QueueMusic), Triple("radios", "Radio", Icons.Default.Radio), Triple("downloads", "Downloads", Icons.Default.Download), Triple("history", "Listening history", Icons.Default.History)).forEach { (route, title, icon) -> ActionRow(title, icon) { model.navigate(route, title) } } }
        item { Text("Playlists", Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge) }
        items(page.items, key = { it.id }) { ItemRow(model, it, { model.open(it) }, {}) }
    }
}
@Composable
fun ItemRow(model: AonsokuViewModel, item: LibraryItem, click: () -> Unit, menu: () -> Unit) {
    ListItem(headlineContent = { Text(item.title, maxLines = 1, overflow = TextOverflow.Ellipsis) }, supportingContent = { Text(item.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis) }, leadingContent = { Cover(model, item.cover, Modifier.size(52.dp)) }, trailingContent = { IconButton(menu) { Icon(Icons.Default.MoreVert, "More options for ${item.title}") } }, modifier = Modifier.clickable(onClick = click))
}
@Composable
private fun CollectionScreen(model: AonsokuViewModel, page: NativePage, menu: (LibraryItem) -> Unit) {
    val listState = rememberLazyListState()
    var query by rememberSaveable(page.route, page.id) { mutableStateOf(page.query) }
    LaunchedEffect(query) { kotlinx.coroutines.delay(250); if (query != page.query) model.filter(query = query) }
    LazyColumn(state = listState, contentPadding = PaddingValues(bottom = 24.dp)) {
        if (page.route in listOf("search", "songs", "albums", "artists", "favorites")) item { OutlinedTextField(query, { query = it }, leadingIcon = { Icon(Icons.Default.Search, null) }, placeholder = { Text("Search your library") }, singleLine = true, shape = CircleShape, modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) }
        if (page.items.any { it.kind == "song" }) item { Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) { Button({ model.playPage() }) { Icon(Icons.Default.PlayArrow, null); Text("Play") }; FilledTonalButton({ model.playPage(true) }) { Icon(Icons.Default.Shuffle, null); Text("Shuffle") }; Text("${page.total} songs", Modifier.align(Alignment.CenterVertically), style = MaterialTheme.typography.labelMedium) } }
        if (page.error != null) item { Text(page.error, Modifier.padding(20.dp)); TextButton({ model.reload() }) { Text("Retry") } }
        itemsIndexed(page.items, key = { index, item -> "${item.kind}:${item.id}:$index" }) { index, item -> ItemRow(model, item, { if (item.kind == "song") model.playItems(page.items.filter { it.kind == "song" }, page.items.take(index).count { it.kind == "song" }) else model.open(item) }, { menu(item) }) }
        item {
            if (page.loading) Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else if (page.items.isEmpty()) Text(if (page.route == "search" && query.isBlank()) "Find songs, artists and albums" else "Nothing here yet. Refresh your library to get started.", Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            else if (page.items.size < page.total) TextButton({ model.reload(true) }, Modifier.fillMaxWidth()) { Text("Load more") }
        }
    }
}
@Composable
private fun PlayerSheet(model: AonsokuViewModel, close: () -> Unit) {
    val queue by model.queue.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    ModalBottomSheet(close, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(24.dp).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Cover(model, queue.currentSong?.coverArtId, Modifier.fillMaxWidth().aspectRatio(1f))
            Text(queue.currentSong?.title.orEmpty(), Modifier.padding(top = 24.dp), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Text(queue.currentSong?.artist.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Slider(playback.currentTimeSeconds.toFloat().coerceIn(0f, playback.durationSeconds.toFloat().coerceAtLeast(1f)), { model.command(AudioCommand.Seek(it.toDouble())) }, valueRange = 0f..playback.durationSeconds.toFloat().coerceAtLeast(1f))
            Text("${formatTime(playback.currentTimeSeconds)} / ${formatTime(playback.durationSeconds)}")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                IconButton({ model.command(AudioCommand.SetShuffle(!queue.isShuffleActive)) }) { Icon(Icons.Default.Shuffle, "Shuffle", tint = if (queue.isShuffleActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface) }
                IconButton({ model.command(AudioCommand.Previous) }) { Icon(Icons.Default.SkipPrevious, "Previous") }
                FilledIconButton({ model.command(AudioCommand.TogglePlayPause) }, Modifier.size(72.dp)) { Icon(if (playback.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, "Play or pause", Modifier.size(36.dp)) }
                IconButton({ model.command(AudioCommand.Next) }) { Icon(Icons.Default.SkipNext, "Next") }
                IconButton({ model.command(AudioCommand.SetRepeat(when (queue.repeatMode) { "off" -> "all"; "all" -> "one"; else -> "off" })) }) { Icon(if (queue.repeatMode == "one") Icons.Default.RepeatOne else Icons.Default.Repeat, "Repeat ${queue.repeatMode}", tint = if (queue.repeatMode != "off") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface) }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
fun formatTime(seconds: Double): String = "${seconds.toInt() / 60}:${(seconds.toInt() % 60).toString().padStart(2, '0')}"
