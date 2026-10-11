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
    val starred: Boolean = false, val song: SongEntity? = null,
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

class AonsokuViewModel(application: Application, private val saved: SavedStateHandle) : AndroidViewModel(application) {
    val services = AppServices.getInstance(application)
    private val _signedIn = MutableStateFlow(services.authentication.hasCredentials())
    val signedIn = _signedIn.asStateFlow()
    private val _page = MutableStateFlow(NativePage())
    val page = _page.asStateFlow()
    val home = MutableStateFlow<List<HomeSection>>(emptyList())
    val preferences = MutableStateFlow<Map<String, String>>(emptyMap())
    val playback = MutableStateFlow(AudioPlaybackSnapshot())
    val queue = MutableStateFlow(AudioQueueSnapshot())
    val messages = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val sync = services.library.syncState
    var playbackService: PlaybackService? = null
        private set
    var audio: AudioService? = null
        private set
    private var bound = false
    private var audioJobs = mutableListOf<Job>()
    private var loadJob: Job? = null
    private val history = ArrayDeque<NativePage>()
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val local = binder as? PlaybackService.LocalBinder ?: return
            playbackService = local.getService()
            audio = local.getAudioService()
            audioJobs += viewModelScope.launch { audio!!.playbackState.collect { playback.value = it } }
            audioJobs += viewModelScope.launch { audio!!.queueState.collect { queue.value = it } }
            audioJobs += viewModelScope.launch { audio!!.events.collect { if (it is AudioEvent.Error) messages.emit(it.message) } }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            audioJobs.forEach(Job::cancel); audioJobs.clear()
            audio = null; playbackService = null
        }
    }
    init {
        val context = getApplication<Application>()
        val intent = Intent(context, PlaybackService::class.java)
        context.startService(intent)
        bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        viewModelScope.launch {
            preferences.value = services.preferences.getAllPreferences()
            services.preferences.changes.collect { preferences.value = it.preferences }
        }
        viewModelScope.launch {
            services.library.initialize()
            if (_signedIn.value) {
                if (services.library.isDataAvailableOffline() == null) services.library.syncAll()
                navigate(saved["route"] ?: "home", saved["title"] ?: "Home", saved["id"], false)
            }
        }
        viewModelScope.launch { services.library.dataChanges.debounce(250).collect { reload() } }
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
        if (result.success) { services.library.refreshCredentials(); services.library.syncAll(); navigate("home", "Home", push = false) }
        else messages.emit(result.error ?: "Unable to sign in")
        done(result.success)
    }
    fun navigate(route: String, title: String, id: String? = null, push: Boolean = true) {
        if (push) history.addLast(_page.value)
        _page.value = NativePage(route, title, id)
        saved["route"] = route; saved["title"] = title; saved["id"] = id
        reload()
    }
    fun back(): Boolean {
        if (history.isEmpty()) return false
        _page.value = history.removeLast(); reload(); return true
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
                    "home" -> {
                        home.value = listOf("Recently played" to "played", "Most played" to "playCount", "Recently added" to "created", "Explore" to "random").map { (title, sort) ->
                            HomeSection(title, sort, l.getAlbums(LibraryPagination(12, 0), AlbumFilter(sortBy = sort)).items.map { it.item() })
                        }
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
        if (item.kind == "song") playItems(listOf(item), 0)
        else navigate(item.kind, item.title, item.id)
    }
    fun command(command: AudioCommand) = launch {
        val a = audio ?: error("Playback service is connecting")
        val result = a.execute(command)
        if (result is AudioCommandResult.Failure) messages.emit(result.message)
    }
    fun playItems(items: List<LibraryItem>, index: Int) = command(AudioCommand.PlaySongsById(items.filter { it.kind == "song" }.map { it.id }, index))
    fun playPage(shuffle: Boolean = false) {
        val p = page.value
        when (p.route) {
            "album" -> command(AudioCommand.PlayAlbumById(p.id!!, 0, shuffle))
            "playlist" -> command(AudioCommand.PlayPlaylistById(p.id!!, 0, shuffle))
            else -> { val songs = p.items.filter { it.kind == "song" }; playItems(if (shuffle) songs.shuffled() else songs, 0) }
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
