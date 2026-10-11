package github.realtvop.aonsoku.ui

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.audio.*
import github.realtvop.aonsoku.plugins.data.*
import github.realtvop.aonsoku.plugins.data.db.entity.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject

/** UI state never opens Room, creates a player, or holds a Capacitor plugin. */
data class LibraryItem(
    val id: String, val title: String, val subtitle: String = "",
    val cover: String? = null, val kind: String = "song",
    val starred: Boolean = false, val song: SongEntity? = null, val radio: NativeRadio? = null, val position: Int? = null,
)
fun SongEntity.item() = LibraryItem(id, title, artist.orEmpty(), coverArt ?: albumId, "song", starred != null, this)
fun AlbumEntity.item() = LibraryItem(id, name, "$artist · $songCount songs", coverArt ?: id, "album", starred != null)
fun ArtistEntity.item() = LibraryItem(id, name, "$albumCount albums", coverArt ?: id, "artist", starred != null)
fun PlaylistEntity.item() = LibraryItem(id, name, "$songCount songs", coverArt, "playlist", starred != null)

data class NativePage(
    val route: String = "home", val title: String = "Home", val id: String? = null,
    val items: List<LibraryItem> = emptyList(), val total: Int = 0,
    val loading: Boolean = true, val error: String? = null,
    val query: String = "", val sort: String = "name", val genre: String? = null,
    val fromYear: Int? = null, val toYear: Int? = null,
)
data class HomeSection(val title: String, val sort: String, val items: List<LibraryItem>)

@OptIn(FlowPreview::class)
class AonsokuViewModel(application: Application, private val saved: SavedStateHandle) : AndroidViewModel(application) {
    val services = AppServices.getInstance(application)
    private val _signedIn = MutableStateFlow(services.authentication.hasCredentials())
    val signedIn = _signedIn.asStateFlow()
    private val _page = MutableStateFlow(NativePage())
    val page = _page.asStateFlow()
    val network = github.realtvop.aonsoku.plugins.network.NativeNetworkMonitor.getInstance(application)
    var hapticFeedback: () -> Unit = {}
    val coordinator = github.realtvop.aonsoku.plugins.coordination.CoordinationController.getInstance(application)
    private var localPlayback = AudioPlaybackSnapshot()
    private var localQueue = AudioQueueSnapshot()
    private var previousTarget: String? = null
    val canGoBack = MutableStateFlow(false)
    val lyricsService = github.realtvop.aonsoku.plugins.lyrics.LyricsService(services.library, services.preferences)
    val lyricsRevision = MutableStateFlow(0)
    val libraryRevision = MutableStateFlow(0)
    val downloads = MutableStateFlow<Map<String, NativeDownloadState>>(emptyMap())
    val home = MutableStateFlow<List<HomeSection>>(emptyList())
    val preferences = MutableStateFlow<Map<String, String>>(emptyMap())
    val playback = MutableStateFlow(AudioPlaybackSnapshot())
    val queue = MutableStateFlow(AudioQueueSnapshot())
    val dialog = MutableStateFlow<NativeDialog?>(null)
    val playerExpanded = MutableStateFlow(false)
    val messages = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val sync = services.library.syncState
    var audio: AudioService? = null
        private set
    private var bound = false
    private var audioJobs = mutableListOf<Job>()
    private var loadJob: Job? = null
    private val history = ArrayDeque<NativePage>()
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val local = binder as? PlaybackService.LocalBinder ?: return
            audio = local.getAudioService()
            audioJobs += viewModelScope.launch { audio!!.downloadService()!!.states.collect { val old = downloads.value; downloads.value = it; if (page.value.route == "downloads" && (old.keys != it.keys || old.mapValues { row -> row.value.status } != it.mapValues { row -> row.value.status })) reload() } }
            audioJobs += viewModelScope.launch { audio!!.playbackState.collect { localPlayback = it; if (coordinator.controlledDeviceId.value == null) playback.value = it } }
            audioJobs += viewModelScope.launch { audio!!.queueState.collect { localQueue = it; if (coordinator.controlledDeviceId.value == null) queue.value = it } }
            audioJobs += viewModelScope.launch { audio!!.events.collect { if (it is AudioEvent.Error) messages.emit(it.message) } }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            audioJobs.forEach(Job::cancel); audioJobs.clear()
            audio = null
        }
    }
    init {
        val context = getApplication<Application>()
        val intent = Intent(context, PlaybackService::class.java)
        bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        viewModelScope.launch {
            preferences.value = services.preferences.getAllPreferences()
            if (services.preferences.getPlayHistory(1).isEmpty() && preferences.value["native.history.migrated"] != "true") {
                val legacy = runCatching { JSONObject(preferences.value["player_history"] ?: "{}").getJSONObject("state").getJSONArray("history") }.getOrDefault(JSONArray())
                services.preferences.replacePlayHistory((0 until legacy.length()).mapNotNull { legacy.optJSONObject(it)?.let { row -> (row.optJSONObject("song") ?: row).toString() } })
                services.preferences.setPreference("native.history.migrated", "true")
            }
            services.preferences.changes.collect { preferences.value = it.preferences }
        }
        viewModelScope.launch {
            services.library.initialize()
            if (_signedIn.value) {
                if (services.library.isDataAvailableOffline() == null) services.library.syncAll()
                navigate(saved["route"] ?: "home", saved["title"] ?: "Home", saved["id"], false)
            }
        }
        viewModelScope.launch { coordinator.notices.collect { messages.emit(it) } }
        viewModelScope.launch {
            combine(coordinator.controlledDeviceId, coordinator.devices) { target, devices -> target to devices.find { it.id == target } }.collectLatest { (target, device) ->
                if (previousTarget != target) { dialog.value = null; previousTarget = target }
                if (target == null) { playback.value = localPlayback; queue.value = localQueue; return@collectLatest }
                val snapshot = device?.snapshot
                if (snapshot == null || !device.online) { playback.value = AudioPlaybackSnapshot(state = "disconnected"); queue.value = AudioQueueSnapshot(); return@collectLatest }
                fun ids(key: String) = snapshot.optJSONArray(key)?.let { a -> (0 until a.length()).map { a.optString(it) } }.orEmpty()
                val all = (ids("contextQueue") + ids("userQueue") + ids("restorePrevious") + listOf(snapshot.optString("songId"))).distinct()
                val songs = services.library.getSongsByIds(all).associateBy { it.id }
                fun convert(id: String): QueueSong = songs[id]?.let { song -> QueueSong(song.id, song.title, song.artist.orEmpty(), song.artistId, song.album.orEmpty(), song.albumId, song.duration.toDouble(), song.coverArt ?: song.albumId, "aonsoku-media://stream?id=${song.id}", null) } ?: QueueSong(id, id, "", null, "", null, 0.0, null, "", null)
                queue.value = AudioQueueSnapshot(contextSongs = ids("contextQueue").map(::convert), currentIndex = snapshot.optInt("contextIndex"), userQueue = ids("userQueue").map(::convert), isInUserQueue = snapshot.optBoolean("inUserQueue"), playedUserQueueHistory = ids("restorePrevious").map(::convert), currentSong = snapshot.optString("songId").takeIf(String::isNotBlank)?.let(::convert), isShuffleActive = snapshot.optBoolean("shuffle"), repeatMode = snapshot.optString("repeat", "off"), sourceName = device.name, sourceId = snapshot.optString("sourceId").takeIf { it.contains(":") }?.let { QueueSourceId(it.substringBefore(":"), it.substringAfter(":")) })
                playback.value = AudioPlaybackSnapshot(songId = snapshot.optString("songId"), isPlaying = snapshot.optBoolean("isPlaying"), currentTimeSeconds = snapshot.optDouble("progressSeconds"), durationSeconds = snapshot.optDouble("durationSeconds"), volume = snapshot.optDouble("volume", 1.0))
            }
        }
        viewModelScope.launch {
            while (true) {
                delay(500)
                val target = coordinator.controlledDeviceId.value ?: continue
                val device = coordinator.devices.value.find { it.id == target } ?: continue
                val snapshot = device.snapshot ?: continue
                if (device.online && snapshot.optBoolean("isPlaying")) {
                    val elapsed = (System.currentTimeMillis() - device.confirmedAt).coerceAtLeast(0) / 1000.0
                    val duration = snapshot.optDouble("durationSeconds")
                    playback.value = playback.value.copy(currentTimeSeconds = (snapshot.optDouble("progressSeconds") + elapsed).coerceAtMost(duration.takeIf { it > 0 } ?: Double.MAX_VALUE))
                }
            }
        }
        viewModelScope.launch { services.library.dataChanges.debounce(250).collect { libraryRevision.value++; reload() } }
    }
    fun launch(block: suspend () -> Unit) = viewModelScope.launch {
        try { block() } catch (e: CancellationException) { throw e }
        catch (e: Exception) { messages.emit(e.message ?: "Operation failed") }
    }
    fun login(url: String, fallback: String, username: String, password: String, done: (Boolean) -> Unit) = launch {
        val validUrl = runCatching { java.net.URI(url) }.getOrNull()
        if (validUrl?.scheme !in listOf("http", "https") || validUrl?.host.isNullOrBlank()) {
            messages.emit("Enter a valid http or https server URL"); done(false); return@launch
        }
        val result = services.authentication.login(url.trim().trimEnd('/'), fallback.trim().takeIf(String::isNotEmpty), username.trim(), password)
        _signedIn.value = result.success
        if (result.success) { setPreference("app_store.data.primaryUrl", url.trim().trimEnd('/')); setPreference("app_store.data.fallbackUrl", fallback.trim()); services.library.refreshCredentials(); services.library.syncAll(); navigate("home", "Home", push = false) }
        else messages.emit(result.error ?: "Unable to sign in")
        done(result.success)
    }
    fun navigate(route: String, title: String, id: String? = null, push: Boolean = true) {
        if (push) history.addLast(_page.value)
        canGoBack.value = history.isNotEmpty()
        _page.value = NativePage(route, title, id)
        saved["route"] = route; saved["title"] = title; saved["id"] = id
        reload()
    }
    fun back(): Boolean {
        if (history.isEmpty()) return false
        _page.value = history.removeLast(); canGoBack.value = history.isNotEmpty(); reload(); return true
    }
    fun root(route: String, title: String) { history.clear(); navigate(route, title, push = false) }
    fun filter(query: String = page.value.query, sort: String = page.value.sort, genre: String? = page.value.genre, fromYear: Int? = page.value.fromYear, toYear: Int? = page.value.toYear) {
        _page.value = _page.value.copy(query = query, sort = sort, genre = genre, fromYear = fromYear, toYear = toYear, items = emptyList())
        reload()
    }
    fun reload(more: Boolean = false) {
        loadJob?.cancel()
        loadJob = launch {
            val p = _page.value
            _page.value = p.copy(loading = true, error = null)
            try {
                val l = services.library
                val paging = LibraryPagination(80, if (more) p.items.size else 0)
                var total = 0
                val items = when (p.route) {
                    "top-songs" -> l.getTopSongs(p.id.orEmpty()).map { it.item() }.also { total = it.size }
                    "favorites-albums" -> l.getAlbums(paging, AlbumFilter(starredOnly = true, sortBy = "starredAt")).let { total = it.total; it.items.map { row -> row.item() } }
                    "favorites-artists" -> l.getArtists(paging, ArtistFilter(starredOnly = true)).let { total = it.total; it.items.map { row -> row.item() } }
                    "favorites-songs" -> l.getSongs(paging, SongFilter(starredOnly = true, sortBy = "starredAt")).let { total = it.total; it.items.map { row -> row.item() } }
                    "downloads" -> withContext(Dispatchers.IO) { audio?.downloadService()?.cachedAudio().orEmpty().map { it.songId } }.let { ids -> (ids + downloads.value.keys).distinct().let { all -> val songs = l.getSongsByIds(all).associateBy { it.id }; all.mapNotNull { id -> (songs[id] ?: audio?.downloadService()?.cachedSong(id))?.item()?.let { if (songs[id] == null) it.copy(subtitle = "${it.subtitle} · Removed from server (still playable offline)") else it } } } }.also { total = it.size }
                    "radios" -> l.getRadios().map { LibraryItem(it.id, it.name, it.streamUrl, kind = "radio", radio = it) }.also { total = it.size }
                    "history" -> services.preferences.getPlayHistory(10000).mapNotNull { runCatching { JSONObject(it).optString("id") }.getOrNull() }.let { ids -> val songs = l.getSongsByIds(ids).associateBy { it.id }; ids.mapNotNull { songs[it]?.item() } }.also { total = it.size }
                    "home" -> {
                        home.value = listOf("Recently played" to "played", "Most played" to "playCount", "Recently added" to "created", "Explore" to "random").map { (title, sort) ->
                            HomeSection(title, sort, l.getAlbums(LibraryPagination(12, 0), AlbumFilter(sortBy = sort)).items.map { it.item() })
                        }
                        val pins = runCatching { JSONArray(preference("pinned_home_store.items") ?: "[]") }.getOrDefault(JSONArray())
                        val pinned = (0 until pins.length()).mapNotNull { index ->
                            val pin = pins.getJSONObject(index)
                            if (pin.optString("type") == "album") l.getAlbum(pin.optString("id"))?.first?.item()
                            else l.getPlaylist(pin.optString("id"))?.let { LibraryItem(it.id, it.name, "${it.songCount} songs", it.coverArt, "playlist") }
                        }
                        if (pinned.isNotEmpty()) home.value = listOf(HomeSection("Pinned", "pinned", pinned)) + home.value
                        emptyList()
                    }
                    "library", "playlists" -> l.getPlaylists(paging).let { total = it.total; it.items.map { row -> row.item() } }
                    "albums" -> l.getAlbums(paging, AlbumFilter(search = p.query.takeIf(String::isNotBlank), genre = p.genre, fromYear = p.fromYear, toYear = p.toYear, sortBy = p.sort)).let { total = it.total; it.items.map { row -> row.item() } }
                    "artists" -> l.getArtists(paging, ArtistFilter(search = p.query.takeIf(String::isNotBlank), sortBy = p.sort)).let { total = it.total; it.items.map { row -> row.item() } }
                    "artist" -> l.getAlbums(paging, AlbumFilter(artistId = p.id, sortBy = p.sort)).let { total = it.total; it.items.map { row -> row.item() } }
                    "album" -> l.getAlbum(p.id!!)?.second.orEmpty().map { it.item() }.also { total = it.size }
                    "playlist" -> {
                        val entries = JSONArray(l.getPlaylist(p.id!!)?.entriesJson ?: "[]")
                        val ids = (0 until entries.length()).mapNotNull { entries.optJSONObject(it)?.optString("id") }
                        val songs = l.getSongsByIds(ids).associateBy { it.id }
                        ids.mapNotNull { songs[it]?.item() }.also { total = it.size }
                    }
                    "search" -> l.search(p.query, 20, 30, 80).let { result -> (result.artists.map { it.item() } + result.albums.map { it.item() } + result.songs.map { it.item() }).also { total = it.size } }
                    "favorites", "songs" -> l.getSongs(paging, SongFilter(search = p.query.takeIf(String::isNotBlank), starredOnly = p.route == "favorites", artistId = p.id, sortBy = if (p.sort == "name") "title" else p.sort)).let { total = it.total; it.items.map { row -> row.item() } }
                    else -> emptyList()
                }
                _page.value = p.copy(items = if (more) p.items + items else items, total = total, loading = false)
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { _page.value = p.copy(loading = false, error = e.message ?: "Unable to load library") }
        }
    }
    fun open(item: LibraryItem) {
        if (item.kind == "radio") {
            item.radio?.let { radio -> replaceQueue(AudioCommand.SetContextQueue(listOf(QueueSong("radio:${radio.id}", radio.name, "Live radio", null, "", null, 0.0, null, radio.streamUrl, null)), 0, true, null, QueueSourceId("radio", radio.id), radio.name, "off")) }
        } else if (item.kind == "song") playItems(listOf(item), 0)
        else navigate(item.kind, item.title, item.id)
    }
    fun command(command: AudioCommand) = launch {
        if (booleanPreference("player_store.settings.hapticFeedback.hapticFeedbackEnabled", true)) hapticFeedback()
        if (coordinator.controlledDeviceId.value != null) { coordinator.send(remoteCommand(command)); return@launch }
        val a = audio ?: error("Playback service is connecting")
        getApplication<Application>().startService(Intent(getApplication(), PlaybackService::class.java))
        val result = a.execute(command)
        if (result is AudioCommandResult.Failure) messages.emit(result.message)
    }
    fun playItems(items: List<LibraryItem>, index: Int) = replaceQueue(AudioCommand.PlaySongsById(items.filter { it.kind == "song" }.map { it.id }, index))
    fun playPage(shuffle: Boolean = false, index: Int = 0) {
        val p = page.value
        when (p.route) {
            "album" -> replaceQueue(AudioCommand.PlayAlbumById(p.id!!, index, shuffle))
            "playlist" -> replaceQueue(AudioCommand.PlayPlaylistById(p.id!!, index, shuffle))
            else -> launch {
                val songs = if (p.route in listOf("songs", "favorites", "favorites-songs")) {
                    val result = mutableListOf<LibraryItem>()
                    var offset = 0
                    do {
                        val batch = services.library.getSongs(LibraryPagination(500, offset), SongFilter(search = p.query.takeIf(String::isNotBlank), starredOnly = p.route != "songs", artistId = p.id, sortBy = if (p.sort == "name") "title" else p.sort))
                        result += batch.items.map { it.item() }; offset += batch.items.size
                    } while (batch.hasMore)
                    result
                } else p.items.filter { it.kind == "song" }
                playItems(if (shuffle) songs.shuffled() else songs, index)
            }
        }
    }
    private fun remoteCommand(command: AudioCommand): JSONObject {
        val json = JSONObject()
        when (command) {
            AudioCommand.Play -> json.put("type", "play")
            AudioCommand.Pause -> json.put("type", "pause")
            AudioCommand.TogglePlayPause -> json.put("type", "toggle_play_pause")
            AudioCommand.Next -> json.put("type", "next")
            AudioCommand.Previous -> json.put("type", "previous")
            is AudioCommand.Seek -> json.put("type", "seek").put("seconds", command.positionSeconds)
            is AudioCommand.SetVolume -> json.put("type", "set_volume").put("volume", command.value)
            is AudioCommand.SetShuffle -> json.put("type", "set_shuffle").put("enabled", command.enabled)
            is AudioCommand.SetRepeat -> json.put("type", "set_repeat").put("mode", command.mode)
            is AudioCommand.PlaySongById -> json.put("type", "play_song").put("song_id", command.songId)
            is AudioCommand.PlayAlbumById -> json.put("type", "play_album").put("album_id", command.albumId).put("index", command.index).put("shuffle", command.shuffle)
            is AudioCommand.PlayPlaylistById -> json.put("type", "play_playlist").put("playlist_id", command.playlistId).put("index", command.index).put("shuffle", command.shuffle)
            is AudioCommand.PlaySongsById -> json.put("type", "play_at_index").put("song_ids", JSONArray(command.songIds)).put("index", command.index)
            is AudioCommand.AddSongsById -> json.put("type", if (command.position == "next") "add_to_queue_next" else "add_to_queue_last").put("song_ids", JSONArray(command.songIds))
            is AudioCommand.RemoveSongsById -> json.put("type", "remove_from_queue").put("song_ids", JSONArray(command.songIds))
            is AudioCommand.RemoveFromUserQueue -> json.put("type", "remove_from_queue").put("song_ids", JSONArray(command.indices.mapNotNull { queue.value.userQueue.getOrNull(it)?.id }))
            is AudioCommand.ReorderContextQueue -> json.put("type", "reorder_queue").put("from", command.fromIndex).put("to", command.toIndex)
            is AudioCommand.ReorderUserQueue -> json.put("type", "reorder_queue").put("from", queue.value.contextSongs.size + command.fromIndex).put("to", queue.value.contextSongs.size + command.toIndex)
            AudioCommand.ClearUserQueue -> json.put("type", "clear_queue")
            is AudioCommand.PlayAtIndex -> json.put("type", "play_at_index").put("song_ids", JSONArray(queue.value.contextSongs.map { it.id })).put("index", command.index)
            is AudioCommand.PlayUserQueueAtIndex -> json.put("type", "play_at_index").put("song_ids", JSONArray((queue.value.contextSongs + queue.value.userQueue).map { it.id })).put("index", queue.value.contextSongs.size + command.index)
            else -> error("This action is available on the playback device")
        }
        return json
    }
    fun selectionActions(items: List<LibraryItem>, indices: List<Int>) {
        val page = page.value
        fun withIds(action: suspend (List<String>) -> Unit) { launch { action(items.flatMap { songIds(it) }) } }
        val actions = mutableListOf<Pair<String, () -> Unit>>(
            "Play" to { withIds { ids -> replaceQueue(AudioCommand.PlaySongsById(ids, 0)) }; Unit },
            "Play next" to { withIds { command(AudioCommand.AddSongsById(it, "next")) }; Unit },
            "Add to queue" to { withIds { command(AudioCommand.AddSongsById(it, "last")) }; Unit },
            "Add to playlist" to { withIds { addToPlaylist(it) }; Unit },
            "Download" to { items.forEach { download(it) }; Unit },
            "Add to favorites" to { launch { items.filter { it.kind in listOf("song", "album", "artist") }.forEach { services.library.setStarred(it.id, it.kind, true) } }; Unit },
            "Remove from favorites" to { launch { items.filter { it.kind in listOf("song", "album", "artist") }.forEach { services.library.setStarred(it.id, it.kind, false) } }; Unit },
        )
        if (page.route == "playlist") actions += "Remove from playlist" to { dialog.value = NativeDialog.Confirm("Remove songs?", "Remove ${items.size} songs from ${page.title}?") { launch { services.library.updatePlaylist(page.id!!, removeIndices = indices); reload() } }; Unit }
        if (page.route == "downloads") actions += "Delete downloads" to { dialog.value = NativeDialog.Confirm("Delete downloads?", "Remove ${items.size} downloaded files?") { launch { withContext(Dispatchers.IO) { items.forEach { audio?.downloadService()?.deleteCachedAudio(it.id) } }; reload() } }; Unit }
        dialog.value = NativeDialog.Choose("${items.size} selected", actions)
    }
    fun playItem(item: LibraryItem, shuffle: Boolean = false) {
        when (item.kind) {
            "album" -> replaceQueue(AudioCommand.PlayAlbumById(item.id, 0, shuffle))
            "playlist" -> replaceQueue(AudioCommand.PlayPlaylistById(item.id, 0, shuffle))
            else -> open(item)
        }
    }
    private fun replaceQueue(command: AudioCommand) {
        val q = queue.value
        val sameContext = when (command) {
            is AudioCommand.PlayAlbumById -> q.sourceId?.type == "album" && q.sourceId?.id == command.albumId && !command.shuffle
            is AudioCommand.PlayPlaylistById -> q.sourceId?.type == "playlist" && q.sourceId?.id == command.playlistId && !command.shuffle
            else -> false
        }
        if (sameContext) {
            val index = when (command) { is AudioCommand.PlayAlbumById -> command.index; is AudioCommand.PlayPlaylistById -> command.index; else -> q.currentIndex }
            command(if (index == q.currentIndex && !q.isInUserQueue) AudioCommand.Play else AudioCommand.PlayAtIndex(index, null))
            return
        }
        val remaining = q.userQueue.drop(if (q.isInUserQueue) 1 else 0)
        val play = { command(command); if (booleanPreference("player_store.settings.fullscreen.autoFullscreenEnabled", false)) playerExpanded.value = true; Unit }
        if (playback.value.isPlaying && remaining.isNotEmpty()) dialog.value = NativeDialog.Confirm("Replace queue?", "${remaining.size} manually added songs remain. Replace the current queue?", play)
        else play()
    }
    suspend fun songIds(item: LibraryItem): List<String> = when (item.kind) {
        "song" -> listOf(item.id)
        "album" -> services.library.getAlbum(item.id)?.second.orEmpty().map { it.id }
        "playlist" -> services.library.getPlaylist(item.id)?.entriesJson?.let { raw -> val entries = JSONArray(raw); (0 until entries.length()).mapNotNull { entries.optJSONObject(it)?.optString("id") } }.orEmpty()
        else -> emptyList()
    }
    fun download(item: LibraryItem) = launch { getApplication<Application>().startService(Intent(getApplication(), PlaybackService::class.java)); songIds(item).forEach { audio?.downloadService()?.download(it) }; messages.emit("Added to downloads") }
    fun lyricsOptions(song: SongEntity) {
        dialog.value = NativeDialog.Choose("Lyrics", listOf(
            "Search lyrics" to { dialog.value = NativeDialog.Form("Search lyrics", listOf(NativeField("title", "Title", song.title), NativeField("artist", "Artist", song.artist.orEmpty()))) { values ->
                val candidates = lyricsService.search(values["title"].orEmpty(), values["artist"].orEmpty())
                dialog.value = NativeDialog.Choose("Choose lyrics", candidates.map { c -> "${c.title} · ${c.artist}" to { launch { lyricsService.select(song.id, c.body, c.romaji); lyricsRevision.value++ }; Unit } })
            }; Unit },
            "Paste lyrics" to { dialog.value = NativeDialog.Form("Paste lyrics", listOf(NativeField("body", "LRC or plain lyrics"))) { values -> lyricsService.select(song.id, values["body"].orEmpty()); lyricsRevision.value++ }; Unit },
            "Timing offset" to { dialog.value = NativeDialog.Form("Timing offset", listOf(NativeField("offset", "Offset in milliseconds", preference("native.lyrics.offset.${song.id}") ?: "0"))) { values -> val offset = values["offset"]?.toIntOrNull() ?: error("Enter a number"); setPreference("native.lyrics.offset.${song.id}", offset); lyricsRevision.value++ }; Unit },
            "Disable lyrics for this song" to { setPreference("native.lyrics.disabled.${song.id}", true); lyricsRevision.value++; Unit },
            "Reset lyrics selection" to { launch { services.preferences.deletePreference("native.lyrics.disabled.${song.id}"); services.preferences.deletePreference("native.lyrics.selected.${song.id}"); lyricsService.load(song, true); lyricsRevision.value++ }; Unit },
        ))
    }
    fun favorite(item: LibraryItem) = launch { services.library.setStarred(item.id, item.kind, !item.starred); reload() }
    fun playlistForm(id: String? = null, songs: List<String> = emptyList()) = launch {
        val detail = id?.let { services.library.getPlaylist(it) }
        dialog.value = NativeDialog.Form(if (id == null) "Create playlist" else "Edit playlist", listOf(NativeField("name", "Name", detail?.name.orEmpty()), NativeField("comment", "Description", detail?.comment.orEmpty()), NativeField("public", "Public playlist", detail?.isPublic.toString(), toggle = true))) { values ->
            if (id == null) services.library.createPlaylist(values["name"].orEmpty(), values["comment"].orEmpty(), values["public"] == "true", songs)
            else services.library.updatePlaylist(id, values["name"], values["comment"], values["public"] == "true")
            reload()
        }
    }
    fun addToPlaylist(songIds: List<String>) = launch {
        val playlists = mutableListOf<PlaylistEntity>()
        var offset = 0
        do { val p = services.library.getPlaylists(LibraryPagination(100, offset)); playlists += p.items; offset += p.items.size } while (p.hasMore)
        val owned = playlists.filter { it.owner == null || it.owner == services.authentication.getCredentials()?.username }
        dialog.value = NativeDialog.Choose("Add to playlist", listOf("New playlist" to { playlistForm(songs = songIds); Unit }) + owned.map { playlist -> playlist.name to { launch { services.library.updatePlaylist(playlist.id, add = songIds); messages.emit("Added to ${playlist.name}") }; Unit } })
    }
    fun radioForm(radio: NativeRadio? = null) {
        dialog.value = NativeDialog.Form(if (radio == null) "Create radio station" else "Edit radio station", listOf(NativeField("name", "Name", radio?.name.orEmpty()), NativeField("stream", "Stream URL", radio?.streamUrl.orEmpty()), NativeField("home", "Homepage URL", radio?.homePageUrl.orEmpty()))) { values ->
            services.library.saveRadio(NativeRadio(radio?.id.orEmpty(), values["name"].orEmpty(), values["stream"].orEmpty(), values["home"].orEmpty())); reload()
        }
    }
    fun pin(item: LibraryItem) {
        val pins = runCatching { JSONArray(preference("pinned_home_store.items") ?: "[]") }.getOrDefault(JSONArray())
        val existing = (0 until pins.length()).map { pins.getJSONObject(it) }
        val next = existing.filterNot { it.optString("id") == item.id && it.optString("type") == item.kind }.toMutableList()
        if (next.size == existing.size) next.add(0, JSONObject().put("id", item.id).put("type", item.kind))
        setPreference("pinned_home_store.items", JSONArray(next)); reload()
    }
    fun logout() {
        dialog.value = NativeDialog.Confirm("Sign out?", "Playback will stop. Your downloaded music and preferences stay on this device.") {
            coordinator.disconnect(); command(AudioCommand.Stop); services.authentication.clearCredentials(); _signedIn.value = false
        }
    }
    fun booleanPreference(path: String, default: Boolean): Boolean = preference(path)?.toBooleanStrictOrNull() ?: default
    fun preference(path: String): String? {
        val split = path.split('.')
        if (split.size == 1 || split.first() == "native") return preferences.value[path]
        var node: Any? = runCatching { JSONObject(preferences.value[split.first()] ?: "{}").optJSONObject("state") }.getOrNull()
        split.drop(1).forEach { node = (node as? JSONObject)?.opt(it) }
        return node?.takeUnless { it == JSONObject.NULL }?.toString()
    }
    fun setPreference(path: String, value: Any) = launch {
        if (path == "player_history.maxSize") coordinator.enqueueHistory(JSONObject().put("kind", "set_limit").put("historyLimit", value.toString().toInt()))
        val split = path.split('.')
        if (split.size == 1 || split.first() == "native") services.preferences.setPreference(path, value.toString())
        else {
            val root = runCatching { JSONObject(preferences.value[split.first()] ?: "{}") }.getOrDefault(JSONObject())
            if (!root.has("state")) root.put("state", JSONObject())
            var node = root.getJSONObject("state")
            split.drop(1).dropLast(1).forEach { key -> if (node.optJSONObject(key) == null) node.put(key, JSONObject()); node = node.getJSONObject(key) }
            node.put(split.last(), value)
            services.preferences.setPreference(split.first(), root.toString())
        }
    }
    override fun onCleared() {
        audioJobs.forEach(Job::cancel)
        if (bound) getApplication<Application>().unbindService(connection)
        super.onCleared()
    }
}
