package github.realtvop.aonsoku.ui

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

private val categories = listOf("server" to "Server", "appearance" to "Appearance", "language" to "Language", "audio" to "Audio", "content" to "Content", "storage" to "Storage", "cross-device" to "Cross-device", "privacy" to "Privacy")

@Composable
fun SettingsScreen(model: AonsokuViewModel, category: String?) {
    val preferences by model.preferences.collectAsState()
    val context = LocalContext.current
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (category == null) {
            val credentials = model.services.authentication.getCredentials()
            Text(credentials?.username.orEmpty(), Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.headlineMedium)
            Text(credentials?.serverUrl.orEmpty(), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            categories.forEach { (route, title) -> ActionRow(title) { model.navigate("settings/$route", title) } }
            ActionRow("Listening history", Icons.Default.History) { model.navigate("history", "Listening history") }
            ActionRow("Debug logs", Icons.Default.BugReport) { context.startActivity(Intent(context, github.realtvop.aonsoku.plugins.debug.DebugActivity::class.java)) }
            ActionRow("Sign out", Icons.Default.Logout) { model.logout() }
            return@Column
        }
        when (category) {
            "server" -> {
                val credentials = model.services.authentication.getCredentials()
                Text("${credentials?.serverType.orEmpty()} · Subsonic ${credentials?.protocolVersion.orEmpty()}", Modifier.padding(20.dp))
                ActionRow("Server addresses", Icons.Default.Dns) {
                    model.dialog.value = NativeDialog.Form("Server addresses", listOf(NativeField("primary", "Primary URL", model.preference("app_store.data.primaryUrl") ?: credentials?.serverUrl.orEmpty()), NativeField("fallback", "Fallback URL", credentials?.fallbackUrl.orEmpty()))) { values ->
                        val c = credentials ?: error("Sign in first")
                        val primary = values["primary"].orEmpty().trim().trimEnd('/')
                        val fallback = values["fallback"].orEmpty().trim().trimEnd('/')
                        require(java.net.URI(primary).scheme in listOf("http", "https")) { "Invalid server URL" }
                        val primaryOk = model.services.authentication.ping(primary, c.username, c.password, c.authType).reachable
                        val target = if (primaryOk) primary else fallback.takeIf { it.isNotBlank() && model.services.authentication.ping(it, c.username, c.password, c.authType).reachable } ?: error("Neither server is reachable")
                        model.services.authentication.storeCredentials(c.copy(serverUrl = target, fallbackUrl = fallback.takeIf(String::isNotBlank)))
                        model.setPreference("app_store.data.primaryUrl", primary)
                        model.setPreference("app_store.data.fallbackUrl", fallback)
                        model.services.library.refreshCredentials()
                    }
                }
                ActionRow("Test connection", Icons.Default.NetworkCheck) { model.launch { val c = credentials ?: error("Sign in first"); val result = model.services.authentication.ping(c.serverUrl, c.username, c.password, c.authType); model.messages.emit(if (result.reachable) "Connected" else "Server is unreachable") } }
                ActionRow("Sign out", Icons.Default.Logout) { model.logout() }
            }
            "appearance" -> {
                Choice(model, "Theme mode", "theme_store.themeMode", "system", listOf("system", "light", "dark"))
                Choice(model, "Light theme", "theme_store.lightTheme", "light", listOf("light", "night-owl-light", "noctis-lilac", "achiever", "tinacious-design"))
                Choice(model, "Dark theme", "theme_store.darkTheme", "dark", listOf("dark", "black", "one-dark", "marmalade-beaver", "material-theme", "monokai-pro", "github-dark", "shades-of-purple", "bearded-solarized", "catppuccin-mocha", "nuclear-dark", "dracula", "discord", "vue-dark", "vim-dark-soft"))
                Toggle(model, "Material You", "theme_store.materialYouEnabled", false)
                Toggle(model, "Open fullscreen player automatically", "player_store.settings.fullscreen.autoFullscreenEnabled", false)
                Toggle(model, "Use album covers for songs", "player_store.settings.coverArt.useAlbumCoverForSongs", false)
            }
            "language" -> Choice(model, "Language", "lang_store.langCode", "", listOf("", "cs", "de", "en-US", "es-ES", "fr", "fr-CA", "it", "ja", "ko", "ml", "pl", "pt", "pt-BR", "ru", "sv", "tr", "uk", "zh-Hans"))
            "audio" -> {
                Toggle(model, "Haptic feedback", "player_store.settings.hapticFeedback.hapticFeedbackEnabled", true)
                Toggle(model, "Hide system volume HUD", "native.hideVolumeHud", false)
                Toggle(model, "ReplayGain", "player_store.settings.replayGain.values.enabled", false)
                Choice(model, "ReplayGain mode", "player_store.settings.replayGain.values.type", "track", listOf("track", "album"))
                NumberSetting(model, "Preamp (dB)", "player_store.settings.replayGain.values.preAmp", 0f, -15f..15f)
                NumberSetting(model, "Default gain (dB)", "player_store.settings.replayGain.values.defaultGain", -6f, -15f..15f)
                Text(L("Lyrics"), Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge)
                Toggle(model, "Prefer synced lyrics", "player_store.settings.lyrics.preferSyncedLyrics", false)
                Toggle(model, "Show translation", "player_store.settings.lyrics.showTranslation", true)
                ActionRow("Lyrics source order") {
                    val current = runCatching { JSONArray(model.preference("player_store.settings.lyrics.sourcePriority") ?: "[\"navidrome\",\"lrclib\",\"custom\"]") }.getOrDefault(JSONArray())
                    val orders = listOf(listOf("navidrome", "lrclib", "custom"), listOf("navidrome", "custom", "lrclib"), listOf("lrclib", "navidrome", "custom"), listOf("lrclib", "custom", "navidrome"), listOf("custom", "navidrome", "lrclib"), listOf("custom", "lrclib", "navidrome"))
                    model.dialog.value = NativeDialog.Choose("Lyrics source order", orders.map { order -> order.joinToString(" → ") to { model.setPreference("player_store.settings.lyrics.sourcePriority", JSONArray(order)); Unit } })
                }
                Toggle(model, "Custom lyrics server", "player_store.settings.lyrics.customServerEnabled", false)
                ActionRow("Custom lyrics server settings") {
                    model.dialog.value = NativeDialog.Form("Custom lyrics server", listOf(NativeField("url", "URL", model.preference("player_store.settings.lyrics.customServerUrl").orEmpty()), NativeField("password", "Password", github.realtvop.aonsoku.plugins.lyrics.LyricsService.decodePassword(model.preference("player_store.settings.lyrics.customServerPassword").orEmpty()), secret = true))) { values ->
                        val url = values["url"].orEmpty().trim()
                        require(url.isEmpty() || java.net.URI(url).scheme in listOf("http", "https")) { "Invalid URL" }
                        model.setPreference("player_store.settings.lyrics.customServerUrl", url)
                        model.setPreference("player_store.settings.lyrics.customServerPassword", values["password"].orEmpty())
                    }
                }
                Choice(model, "Listening history size", "player_history.maxSize", "100", listOf("25", "50", "100", "250", "500", "1000"), numeric = true)
                ActionRow("Clear listening history", Icons.Default.Delete) { model.dialog.value = NativeDialog.Confirm("Clear history?", "This removes listening history and synchronizes the deletion when cross-device playback is enabled.") { model.launch { model.coordinator.enqueueHistory(JSONObject().put("kind", "clear")); model.services.preferences.clearPlayHistory(); model.setPreference("player_history.history", JSONArray()) } } }
            }
            "content" -> Toggle(model, "Hide radio section", "app_store.pages.hideRadiosSection", true)
            "privacy" -> Toggle(model, "LRCLIB", "player_store.settings.privacy.lrcLibEnabled", true)
            "storage" -> {
                val sync by model.sync.collectAsState()
                Text(L("Offline library"), Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge)
                Text(L("Your library is stored on this device for native browsing."), Modifier.padding(horizontal = 20.dp))
                Toggle(model, "Sync cover art", "cache_store.settings.syncCoverArt", false)
                Choice(model, "Cover art concurrency", "cache_store.settings.coverArtConcurrency", "4", (1..8).map(Int::toString), numeric = true)
                ActionRow(if (sync.isSyncing) "Cancel sync" else "Sync now", Icons.Default.Sync) { if (sync.isSyncing) model.services.library.cancelSync() else model.services.library.syncIncremental() }
                ActionRow("Full library refresh", Icons.Default.Refresh) { model.services.library.syncAll() }
                Toggle(model, "Smart downloads", "cache_store.settings.smartRules.enabled", false)
                Toggle(model, "Favorite songs", "cache_store.settings.smartRules.favoriteSongs", true)
                Toggle(model, "Favorite playlists", "cache_store.settings.smartRules.favoritePlaylists", true)
                Choice(model, "Playback cache limit", "cache_store.settings.lruQuota", "1073741824", listOf("0", "268435456", "536870912", "1073741824", "2147483648", "5368709120", "10737418240"), numeric = true, bytes = true)
                Choice(model, "Image cache limit", "cache_store.settings.assetsQuota", "536870912", listOf("0", "134217728", "268435456", "536870912", "1073741824"), numeric = true, bytes = true)
                val stats by produceState("", preferences, model.downloads.collectAsState().value) {
                    val audio = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { model.audio?.downloadService()?.cachedAudio().orEmpty() }
                    val images = model.services.library.cachedImages()
                    value = "${audio.size} songs · ${formatBytes(audio.sumOf { it.sizeBytes })} / ${images.size} images · ${formatBytes(images.sumOf { it.sizeBytes })}"
                }
                Text(stats, Modifier.padding(20.dp), style = MaterialTheme.typography.bodySmall)
                ActionRow("Manage cached images", Icons.Default.Image) { model.navigate("images", "Cached images") }
                ActionRow("Manage downloads", Icons.Default.Download) { model.navigate("downloads", "Downloads") }
                listOf("explicit" to "Clear downloaded songs", "smart" to "Clear smart downloads", "lru" to "Clear playback cache", "assets" to "Clear image cache", "all" to "Clear all caches").forEach { (source, title) -> ActionRow(title, Icons.Default.Delete) { model.dialog.value = NativeDialog.Confirm(title, "Cached files will be removed from this device.") { model.launch { val manager = model.audio?.downloadService(); if (source in listOf("assets", "all")) model.services.library.clearCoverImages(); if (source == "all") manager?.cachedAudio()?.forEach { manager.deleteCachedAudio(it.songId) } else manager?.clearSource(source); model.messages.emit("Cache cleared") } } } }
            }
            "cross-device" -> DeviceScreen(model)
        }
    }
}
@Composable
private fun Toggle(model: AonsokuViewModel, label: String, key: String, default: Boolean) {
    ListItem(headlineContent = { Text(L(label)) }, trailingContent = { Switch(model.booleanPreference(key, default), { model.setPreference(key, it) }) })
}
@Composable
private fun Choice(model: AonsokuViewModel, label: String, key: String, default: String, choices: List<String>, numeric: Boolean = false, bytes: Boolean = false) {
    val value = model.preference(key) ?: default
    ListItem(headlineContent = { Text(L(label)) }, supportingContent = { Text(if (bytes) formatBytes(value.toLongOrNull() ?: 0) else L(value.ifEmpty { "System" })) }, modifier = Modifier.then(Modifier))
    TextButton({ model.dialog.value = NativeDialog.Choose(label, choices.map { option -> (if (bytes) formatBytes(option.toLong()) else option.ifEmpty { "System" }) to { model.setPreference(key, if (numeric) option.toLong() else option); Unit } }) }, Modifier.padding(horizontal = 12.dp)) { Text(L("Change")) }
}
@Composable
private fun NumberSetting(model: AonsokuViewModel, label: String, key: String, default: Float, range: ClosedFloatingPointRange<Float>) {
    var value by remember(model.preferences.value, key) { mutableFloatStateOf(model.preference(key)?.toFloatOrNull() ?: default) }
    Column(Modifier.padding(horizontal = 20.dp)) { Text("${L(label)}: ${value.toInt()}"); Slider(value.coerceIn(range), { value = it }, onValueChangeFinished = { model.setPreference(key, value.toInt()) }, valueRange = range, steps = (range.endInclusive - range.start).toInt() - 1) }
}
fun formatBytes(bytes: Long): String = if (bytes == 0L) "Unlimited" else if (bytes >= 1024L * 1024 * 1024) "${bytes / (1024L * 1024 * 1024)} GB" else "${bytes / (1024 * 1024)} MB"
