package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Article
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.Storage
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.I18n
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.appLanguages
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.session.SessionManager
import github.realtvop.aonsoku.session.SessionState
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.navigation.SettingsRoute
import kotlinx.coroutines.launch

/** The pages of the settings, in the order of the web app. */
enum class SettingsCategory(val id: String, val icon: ImageVector) {
    Server("server", Icons.Rounded.Dns),
    Appearance("appearance", Icons.Rounded.Palette),
    Language("language", Icons.Rounded.Language),
    Audio("audio", Icons.Rounded.Headphones),
    Content("content", Icons.AutoMirrored.Rounded.Article),
    Privacy("privacy", Icons.Rounded.Security),
    Storage("storage", Icons.Rounded.Storage),
    ;

    val titleKey: String get() = "settings.options.$id"
}

/** The list of settings pages, or the page [route] names. */
@Composable
fun SettingsScreen(route: SettingsRoute) {
    if (route.page == CACHE_MANAGER_PAGE) {
        CacheManagerPage()
        return
    }
    when (SettingsCategory.entries.firstOrNull { it.id == route.page }) {
        null -> SettingsRoot()
        SettingsCategory.Server -> ServerSettings()
        SettingsCategory.Appearance -> AppearanceSettings()
        SettingsCategory.Language -> LanguageSettings()
        SettingsCategory.Audio -> AudioSettings()
        SettingsCategory.Content -> ContentSettings()
        SettingsCategory.Privacy -> PrivacySettings()
        SettingsCategory.Storage -> StorageSettings()
    }
}

@Composable
private fun SettingsRoot() {
    val navigator = LocalNavigator.current
    SettingsPage(title = t("settings.label")) {
        settingsSection(key = "pages") {
            for (category in SettingsCategory.entries) {
                item(key = category.id) {
                    SettingRow(
                        title = t(category.titleKey),
                        icon = category.icon,
                        onClick = { navigator.open(SettingsRoute(category.id)) },
                        trailing = {
                            Icon(
                                Icons.AutoMirrored.Rounded.KeyboardArrowRight,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        },
                    )
                }
            }
        }
    }
}

/** The primary and the fallback address of the server, and which one is in use. */
@Composable
private fun ServerSettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val scope = rememberCoroutineScope()
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val session by graph.session.state.collectAsStateWithLifecycle()
    val activeUrl = (session as? SessionState.SignedIn)?.credentials?.serverUrl.orEmpty()
    val server = settings.server

    var primary by rememberSaveable(server.primaryUrl, activeUrl) {
        mutableStateOf(server.primaryUrl.ifEmpty { activeUrl })
    }
    var fallback by rememberSaveable(server.fallbackUrl) { mutableStateOf(server.fallbackUrl) }
    var saving by remember { mutableStateOf(false) }

    val invalidPrimary = t("settings.server.validation.primaryUrl")
    val invalidFallback = t("settings.server.validation.fallbackUrl")
    val saved = t("settings.server.toast.success")
    val unreachable = t("settings.server.toast.error")

    fun save() {
        val primaryUrl = SessionManager.normalizeServerUrl(primary)
        val fallbackUrl = SessionManager.normalizeServerUrl(fallback)
        when {
            !SessionManager.isValidServerUrl(primaryUrl) -> graph.toaster.error(invalidPrimary)
            fallbackUrl.isNotEmpty() && !SessionManager.isValidServerUrl(fallbackUrl) ->
                graph.toaster.error(invalidFallback)
            else -> {
                saving = true
                scope.launch {
                    if (graph.session.saveServerUrls(primaryUrl, fallbackUrl)) {
                        // Another address may be another view of the library.
                        if (graph.session.credentials?.serverUrl != activeUrl) graph.onServerChanged()
                        graph.toaster.success(saved)
                    } else {
                        graph.toaster.error(unreachable)
                    }
                    saving = false
                }
            }
        }
    }

    SettingsPage(title = t("settings.options.server")) {
        settingsSection(
            key = "server",
            title = strings.t("settings.server.group"),
            description = strings.t("settings.server.description"),
        ) {
            item {
                FieldSetting(
                    title = t("settings.server.primaryUrl.label"),
                    info = t("settings.server.primaryUrl.info"),
                    value = primary,
                    onValueChange = { primary = it },
                    placeholder = t("settings.server.primaryUrl.placeholder"),
                    enabled = !saving,
                )
            }
            item {
                FieldSetting(
                    title = t("settings.server.fallbackUrl.label"),
                    info = t("settings.server.fallbackUrl.info"),
                    value = fallback,
                    onValueChange = { fallback = it },
                    placeholder = t("settings.server.fallbackUrl.placeholder"),
                    enabled = !saving,
                )
            }
            item {
                ValueSetting(
                    title = t("settings.server.activeUrl.label"),
                    info = t("settings.server.activeUrl.info"),
                    value = activeUrl.ifEmpty { t("settings.server.activeUrl.empty") },
                )
            }
            item {
                ValueSetting(
                    title = t("settings.server.activeType.label"),
                    info = t("settings.server.activeType.info"),
                    value = t("settings.server.activeType.${server.activeServerType ?: "none"}"),
                )
            }
        }
        item(key = "save") {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Button(onClick = ::save, enabled = !saving) {
                    if (saving) {
                        LoadingIndicator(
                            modifier = Modifier.size(20.dp),
                            color = LocalContentColor.current,
                        )
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(t(if (saving) "settings.server.saving" else "settings.server.save"))
                }
            }
        }
    }
}

@Composable
private fun LanguageSettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    // An empty setting follows the language of the device.
    val current = I18n.languageFor(settings.language)
    SettingsPage(title = t("settings.options.language")) {
        settingsSection(key = "language", title = strings.t("menu.language")) {
            for (language in appLanguages) {
                item(key = language.code) {
                    val selected = language.code == current.code
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = selected,
                                role = Role.RadioButton,
                                onClick = { graph.settings.update { it.copy(language = language.code) } },
                            )
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(text = language.flag, style = MaterialTheme.typography.titleLarge)
                        Spacer(Modifier.width(16.dp))
                        Text(
                            text = language.nativeName,
                            style = MaterialTheme.typography.bodyLarge,
                            modifier = Modifier.weight(1f),
                        )
                        RadioButton(selected = selected, onClick = null)
                    }
                }
            }
        }
    }
}

@Composable
private fun ContentSettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    SettingsPage(title = t("settings.options.content")) {
        settingsSection(
            key = "sidebar",
            title = strings.t("settings.content.sidebar.group"),
            description = strings.t("settings.content.sidebar.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.content.sidebar.radios.section"),
                    checked = settings.hideRadios,
                    onCheckedChange = { hide -> graph.settings.update { it.copy(hideRadios = hide) } },
                )
            }
        }
    }
}

@Composable
private fun PrivacySettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    SettingsPage(title = t("settings.options.privacy")) {
        settingsSection(
            key = "services",
            title = strings.t("settings.privacy.services.group"),
            description = strings.t("settings.privacy.services.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.privacy.services.lrclib.label"),
                    info = t("settings.privacy.services.lrclib.info"),
                    checked = settings.lrcLibEnabled,
                    onCheckedChange = { enabled ->
                        graph.settings.update { it.copy(lrcLibEnabled = enabled) }
                    },
                )
            }
        }
    }
}
