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
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
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
    val haptics = androidx.compose.ui.platform.LocalHapticFeedback.current
    DisposableEffect(model) { model.hapticFeedback = { haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress) }; onDispose { model.hapticFeedback = {} } }
    val language = model.preference("lang_store.langCode").orEmpty()
    val translations = remember(language) { nativeTranslations(context, language) }
    val colors = if (Build.VERSION.SDK_INT >= 31 && model.booleanPreference("theme_store.materialYouEnabled", false)) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else nativeColors(context, model.preference(if (dark) "theme_store.darkTheme" else "theme_store.lightTheme") ?: if (dark) "dark" else "light", dark)
    CompositionLocalProvider(LocalTranslations provides translations) {
    MaterialExpressiveTheme(colorScheme = colors) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            val signedIn by model.signedIn.collectAsStateWithLifecycle()
            if (signedIn) NativeShell(model) else LoginScreen(model)
        }
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
            Text(L("Aonsoku"), style = MaterialTheme.typography.displayMedium, fontWeight = FontWeight.Bold)
            Text(L("Your music, everywhere"), style = MaterialTheme.typography.titleLarge)
            Text(L("Connect to your Navidrome or Subsonic server"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(url, { url = it }, label = { Text(L("Server URL")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(fallback, { fallback = it }, label = { Text(L("Fallback URL (optional)")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(user, { user = it }, label = { Text(L("Username")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text(L("Password")) }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
            Button({ busy = true; model.login(url, fallback, user, password) { busy = false } }, enabled = !busy && url.isNotBlank() && user.isNotBlank(), modifier = Modifier.fillMaxWidth().height(56.dp)) {
                if (busy) CircularProgressIndicator(Modifier.size(24.dp)) else Text(L("Sign in"))
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
    val online by model.network.online.collectAsStateWithLifecycle()
    val playerOpen by model.playerExpanded.collectAsState()
    val canGoBack by model.canGoBack.collectAsState()
    var menuItem by remember { mutableStateOf<LibraryItem?>(null) }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(model) { model.messages.collect { snackbar.showSnackbar(it) } }
    BackHandler(enabled = playerOpen || canGoBack || page.route != "home") { if (playerOpen) model.playerExpanded.value = false else if (!model.back()) model.root("home", "Home") }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(L(page.title), fontWeight = FontWeight.Bold) }, navigationIcon = {
                if (page.route !in listOf("home", "library", "search")) IconButton({ model.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            }, actions = {
                IconButton({ model.services.library.syncIncremental() }) { Icon(Icons.Default.Sync, "Refresh library") }
                IconButton({ model.navigate("settings", "Settings") }) { Icon(Icons.Default.AccountCircle, "Settings and account") }
            })
        },
        bottomBar = {
            Column(Modifier.navigationBarsPadding().padding(horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (queue.currentSong != null) {
                    Surface(onClick = { model.playerExpanded.value = true }, shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp)) {
                        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Cover(model, if (model.booleanPreference("player_store.settings.coverArt.useAlbumCoverForSongs", false)) queue.currentSong?.albumId ?: queue.currentSong?.coverArtId else queue.currentSong?.coverArtId, Modifier.size(48.dp))
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
            if (!online) Text(L("Offline · downloaded music is available"), Modifier.padding(horizontal = 20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (sync.isSyncing) { LinearProgressIndicator(progress = { sync.progress / 100f }, modifier = Modifier.fillMaxWidth()); Text("Syncing ${sync.tier.orEmpty()} · ${sync.processedItems} / ${sync.totalItems}", Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.labelSmall) }
            rememberSaveableStateHolder().SaveableStateProvider("${page.route}:${page.id}") {
            when (page.route) {
                "home" -> HomeScreen(model)
                "library" -> LibraryScreen(model)
                "settings" -> SettingsScreen(model, null)
                "settings/server", "settings/appearance", "settings/language", "settings/audio", "settings/content", "settings/storage", "settings/cross-device", "settings/privacy" -> SettingsScreen(model, page.route.substringAfter('/'))
                else -> CollectionScreen(model, page, { menuItem = it })
            }
            }
        }
    }
    if (playerOpen) NativePlayer(model) { model.playerExpanded.value = false }
    menuItem?.let { item -> NativeItemMenu(model, item) { menuItem = null } }
    if (!playerOpen) NativeDialogs(model)

}

@Composable
private fun RowScope.NavButton(label: String, icon: ImageVector, selected: Boolean, click: () -> Unit) {
    Surface(onClick = click, color = if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent, shape = CircleShape, modifier = Modifier.weight(1f)) {
        Column(Modifier.padding(vertical = 10.dp, horizontal = 14.dp), horizontalAlignment = Alignment.CenterHorizontally) { Icon(icon, label); Text(L(label), style = MaterialTheme.typography.labelMedium) }
    }
}
@Composable
fun ActionRow(label: String, icon: ImageVector = Icons.Default.ChevronRight, click: () -> Unit) {
    ListItem(headlineContent = { Text(L(label)) }, leadingContent = { Icon(icon, null) }, modifier = Modifier.clickable(onClick = click))
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
        item { NativeHomeHero(model, sections) }
        item { ActionRow("Devices", Icons.Default.Devices) { model.navigate("settings/cross-device", "Cross-device") } }
        sections.forEach { section ->
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) { Text(L(section.title), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold); TextButton({ if (section.sort == "pinned") model.dialog.value = NativeDialog.Choose("Pinned", section.items.map { entry -> entry.title to { model.open(entry); Unit } }) else { model.navigate("albums", section.title); model.filter(sort = section.sort) } }) { Text(L("See all")) } }
                LazyRow(contentPadding = PaddingValues(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(section.items, key = { it.id }) { item -> Column(Modifier.width(144.dp).clickable { model.open(item) }) { Cover(model, item.cover, Modifier.size(144.dp)); Text(item.title, Modifier.padding(top = 8.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold); Text(item.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } }
                }
            }
        }
    }
}
@Composable
private fun LibraryScreen(model: AonsokuViewModel) {
    var selected by remember { mutableStateOf<LibraryItem?>(null) }
    selected?.let { NativeItemMenu(model, it) { selected = null } }
    val page by model.page.collectAsStateWithLifecycle()
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        item { listOf(Triple("artists", "Artists", Icons.Default.Mic), Triple("songs", "Songs", Icons.Default.MusicNote), Triple("albums", "Albums", Icons.Default.Album), Triple("favorites", "Favorites", Icons.Default.Favorite), Triple("playlists", "Playlists", Icons.AutoMirrored.Filled.QueueMusic), Triple("downloads", "Downloads", Icons.Default.Download), Triple("history", "Listening history", Icons.Default.History)).forEach { (route, title, icon) -> ActionRow(title, icon) { model.navigate(route, title) } } }
        if (!model.booleanPreference("app_store.pages.hideRadiosSection", true)) item { ActionRow("Radio", Icons.Default.Radio) { model.navigate("radios", "Radio") } }
        item { ActionRow("Create playlist", Icons.Default.Add) { model.playlistForm() } }
        item { Text(L("Playlists"), Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge) }
        items(page.items, key = { it.id }) { ItemRow(model, it, { model.open(it) }, { selected = it }) }
    }
}
@Composable
@OptIn(ExperimentalFoundationApi::class)
fun ItemRow(model: AonsokuViewModel, item: LibraryItem, click: () -> Unit, menu: () -> Unit, selected: Boolean? = null, longClick: (() -> Unit)? = null) {
    ListItem(headlineContent = { Text(item.title, maxLines = 1, overflow = TextOverflow.Ellipsis) }, supportingContent = { Text(item.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis) }, leadingContent = { Cover(model, if (model.booleanPreference("player_store.settings.coverArt.useAlbumCoverForSongs", false)) item.song?.albumId ?: item.cover else item.cover, Modifier.size(52.dp)) }, trailingContent = { if (selected != null) Checkbox(selected, { click() }) else IconButton(menu) { Icon(Icons.Default.MoreVert, "More options for ${item.title}") } }, modifier = Modifier.combinedClickable(onClick = click, onLongClick = longClick))
}
@Composable
private fun CollectionScreen(model: AonsokuViewModel, page: NativePage, menu: (LibraryItem) -> Unit) {
    val listState = rememberLazyListState()
    var selecting by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<Int>()) }
    val grid = model.booleanPreference("native.grid.${page.route}", page.route in listOf("albums", "artists"))
    var query by rememberSaveable(page.route, page.id) { mutableStateOf(page.query) }
    LaunchedEffect(query) { kotlinx.coroutines.delay(250); if (query != page.query) model.filter(query = query) }
    BackHandler(enabled = selecting) { selecting = false; selected = emptySet() }
    LazyColumn(state = listState, contentPadding = PaddingValues(bottom = 24.dp)) {
        if (page.route in listOf("search", "songs", "albums", "artists", "favorites")) item { OutlinedTextField(query, { query = it }, leadingIcon = { Icon(Icons.Default.Search, null) }, placeholder = { Text(L("Search your library")) }, singleLine = true, shape = CircleShape, modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) }
        if (page.route in listOf("albums", "artists", "songs", "favorites")) item { CollectionTools(model, page) }
        if (page.items.isNotEmpty()) item {
            Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton({ selecting = !selecting; selected = emptySet() }) { Text(L(if (selecting) "Cancel selection" else "Select")) }
                if (selecting) {
                    TextButton({ selected = page.items.indices.toSet() }) { Text(L("Select all")) }
                    TextButton({ model.selectionActions(selected.sorted().mapNotNull { page.items.getOrNull(it) }, selected.sorted()); selecting = false; selected = emptySet() }, enabled = selected.isNotEmpty()) { Text("${L("Actions")} (${selected.size})") }
                } else if (page.route in listOf("albums", "artists", "artist", "playlists")) IconButton({ model.setPreference("native.grid.${page.route}", !grid) }) { Icon(if (grid) Icons.Default.ViewList else Icons.Default.GridView, L("Change view")) }
            }
        }
        if (page.route == "search" && page.query.isNotBlank()) item {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) { listOf("artists", "albums", "songs").forEach { kind -> TextButton({ val term = page.query; model.navigate(kind, kind.replaceFirstChar(Char::uppercase)); model.filter(query = term) }) { Text(L("All $kind")) } } }
        }

        if (page.route in listOf("playlists", "radios")) item { ActionRow(if (page.route == "playlists") "Create playlist" else "Create radio station", Icons.Default.Add) { if (page.route == "playlists") model.playlistForm() else model.radioForm() } }
        if (page.route == "playlist") item { Row(Modifier.padding(horizontal = 20.dp)) { TextButton({ model.playlistForm(page.id) }) { Text(L("Edit playlist")) }; TextButton({ model.pin(LibraryItem(page.id!!, page.title, kind = "playlist")) }) { Text(L("Pin or unpin")) } } }
        if (page.route == "album") item { val album by produceState<github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity?>(null, page.id) { value = model.services.library.getAlbum(page.id!!)?.first }; album?.let { a -> Cover(model, a.coverArt ?: a.id, Modifier.padding(horizontal = 24.dp).fillMaxWidth().aspectRatio(1.5f)); Text("${a.artist} · ${a.year ?: ""} · ${a.genre.orEmpty()}", Modifier.padding(20.dp)); Row { TextButton({ model.favorite(a.item()) }) { Text(if (a.starred != null) "Remove from favorites" else "Add to favorites") }; TextButton({ model.pin(a.item()) }) { Text(L("Pin or unpin")) } } } }
        if (page.route == "artist") item { Row { TextButton({ model.navigate("songs", "${page.title} · Songs", page.id) }) { Text(L("All songs")) }; TextButton({ model.navigate("top-songs", "${page.title} · Top songs", page.title) }) { Text(L("Top songs")) }; TextButton({ model.launch { val info = model.services.library.getArtistInfo(page.id!!); model.dialog.value = NativeDialog.Info(page.title, android.text.Html.fromHtml(info.optString("biography"), android.text.Html.FROM_HTML_MODE_LEGACY).toString()) } }) { Text(L("Artist information")) } } }
        if (page.items.any { it.kind == "song" }) item { Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) { Button({ model.playPage() }) { Icon(Icons.Default.PlayArrow, null); Text(L("Play")) }; FilledTonalButton({ model.playPage(true) }) { Icon(Icons.Default.Shuffle, null); Text(L("Shuffle")) }; Text("${page.total} songs", Modifier.align(Alignment.CenterVertically), style = MaterialTheme.typography.labelMedium) } }
        if (page.error != null) item { Text(page.error, Modifier.padding(20.dp)); TextButton({ model.reload() }) { Text(L("Retry")) } }
        if (grid && !selecting && page.route in listOf("albums", "artists", "artist", "playlists")) {
            items(page.items.chunked(2)) { row ->
                Row(Modifier.padding(horizontal = 20.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    row.forEach { entry -> Column(Modifier.weight(1f).clickable { model.open(entry) }) { Cover(model, entry.cover, Modifier.fillMaxWidth().aspectRatio(1f)); Row(verticalAlignment = Alignment.CenterVertically) { Text(entry.title, Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleSmall); IconButton({ menu(entry) }) { Icon(Icons.Default.MoreVert, L("More options")) } }; Text(entry.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall) } }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        } else itemsIndexed(page.items, key = { index, entry -> "${entry.kind}:${entry.id}:$index" }) { index, entry ->
            ItemRow(model, entry, {
                if (selecting) selected = if (index in selected) selected - index else selected + index
                else if (entry.kind == "song") model.playPage(index = page.items.take(index).count { it.kind == "song" }) else model.open(entry)
            }, { menu(entry.copy(position = index)) }, if (selecting) index in selected else null, { selecting = true; selected = selected + index })
            if (page.route == "downloads") DownloadStatus(model, entry)
        }
        item {
            if (page.loading) Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else if (page.items.isEmpty()) Text(if (page.route == "search" && query.isBlank()) "Find songs, artists and albums" else "Nothing here yet. Refresh your library to get started.", Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            else if (page.items.size < page.total) TextButton({ model.reload(true) }, Modifier.fillMaxWidth()) { Text(L("Load more")) }
        }
    }
}
fun formatTime(seconds: Double): String = "${seconds.toInt() / 60}:${(seconds.toInt() % 60).toString().padStart(2, '0')}"
