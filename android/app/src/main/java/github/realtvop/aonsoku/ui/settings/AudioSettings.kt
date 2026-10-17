package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.i18n.LocalStrings
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.session.SessionManager
import github.realtvop.aonsoku.settings.LyricsSettings
import github.realtvop.aonsoku.settings.LyricsSource
import github.realtvop.aonsoku.settings.ReplayGainSettings
import github.realtvop.aonsoku.settings.ReplayGainType
import github.realtvop.aonsoku.ui.components.ReorderableColumn

private val SourceRowHeight = 52.dp

private val PRE_AMP_RANGE = -15..15
private val DEFAULT_GAIN_RANGE = -10..-1
private val HISTORY_RANGE = 10..1000
private const val HISTORY_STEP = 10

/** Haptics, ReplayGain, lyrics, and the play history. */
@Composable
internal fun AudioSettings() {
    val graph = LocalAppGraph.current
    val strings = LocalStrings.current
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val replayGain = settings.replayGain
    val lyrics = settings.lyrics
    val invalidUrl = t("settings.audio.lyrics.customServer.url.invalid")

    fun updateReplayGain(change: (ReplayGainSettings) -> ReplayGainSettings) =
        graph.settings.update { it.copy(replayGain = change(it.replayGain)) }

    fun updateLyrics(change: (LyricsSettings) -> LyricsSettings) =
        graph.settings.update { it.copy(lyrics = change(it.lyrics)) }

    var serverUrl by rememberSaveable(lyrics.customServerUrl) { mutableStateOf(lyrics.customServerUrl) }
    var serverPassword by rememberSaveable(lyrics.customServerPassword) {
        mutableStateOf(lyrics.customServerPassword)
    }

    SettingsPage(title = t("settings.options.audio")) {
        settingsSection(
            key = "haptics",
            title = strings.t("settings.audio.hapticFeedback.group"),
            description = strings.t("settings.audio.hapticFeedback.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.audio.hapticFeedback.enabled.label"),
                    info = t("settings.audio.hapticFeedback.enabled.info"),
                    checked = settings.hapticFeedback,
                    onCheckedChange = { enabled ->
                        graph.settings.update { it.copy(hapticFeedback = enabled) }
                    },
                )
            }
        }

        settingsSection(
            key = "replayGain",
            title = strings.t("settings.audio.replayGain.group"),
            description = strings.t("settings.audio.replayGain.description"),
        ) {
            item(key = "enabled") {
                SwitchSetting(
                    title = t("settings.audio.replayGain.enabled"),
                    checked = replayGain.enabled,
                    onCheckedChange = { enabled -> updateReplayGain { it.copy(enabled = enabled) } },
                )
            }
            if (replayGain.enabled) {
                item(key = "mode") {
                    ChoiceSetting(
                        title = t("settings.audio.replayGain.mode.label"),
                        options = listOf(
                            ReplayGainType.Track to t("settings.audio.replayGain.mode.track"),
                            ReplayGainType.Album to t("settings.audio.replayGain.mode.album"),
                        ),
                        selected = replayGain.type,
                        onSelect = { type -> updateReplayGain { it.copy(type = type) } },
                    )
                }
                item(key = "preAmp") {
                    SliderSetting(
                        title = t("settings.audio.replayGain.preAmp"),
                        value = replayGain.preAmp,
                        onValueChange = { value -> updateReplayGain { it.copy(preAmp = value) } },
                        range = PRE_AMP_RANGE,
                    )
                }
                item(key = "defaultGain") {
                    SliderSetting(
                        title = t("settings.audio.replayGain.defaultGain.label"),
                        info = t("settings.audio.replayGain.defaultGain.info"),
                        value = replayGain.defaultGain,
                        onValueChange = { value -> updateReplayGain { it.copy(defaultGain = value) } },
                        range = DEFAULT_GAIN_RANGE,
                    )
                }
            }
        }

        settingsSection(
            key = "lyrics",
            title = strings.t("settings.audio.lyrics.group"),
            description = strings.t("settings.audio.lyrics.description"),
        ) {
            item {
                SwitchSetting(
                    title = t("settings.audio.lyrics.preferSynced.label"),
                    info = t("settings.audio.lyrics.preferSynced.info"),
                    checked = lyrics.preferSynced,
                    onCheckedChange = { enabled -> updateLyrics { it.copy(preferSynced = enabled) } },
                )
            }
            item {
                SwitchSetting(
                    title = t("settings.audio.lyrics.showTranslation.label"),
                    info = t("settings.audio.lyrics.showTranslation.info"),
                    checked = lyrics.showTranslation,
                    onCheckedChange = { enabled -> updateLyrics { it.copy(showTranslation = enabled) } },
                )
            }
            item {
                LyricsSourcePriority(
                    order = (lyrics.sourcePriority + LyricsSource.entries).distinct(),
                    onReorder = { order -> updateLyrics { it.copy(sourcePriority = order) } },
                )
            }
            item {
                SwitchSetting(
                    title = t("settings.audio.lyrics.customServer.enabled.label"),
                    info = t("settings.audio.lyrics.customServer.enabled.info"),
                    checked = lyrics.customServerEnabled,
                    onCheckedChange = { enabled -> updateLyrics { it.copy(customServerEnabled = enabled) } },
                )
            }
            item {
                FieldSetting(
                    title = t("settings.audio.lyrics.customServer.url.label"),
                    info = t("settings.audio.lyrics.customServer.url.info"),
                    value = serverUrl,
                    onValueChange = { serverUrl = it },
                    placeholder = t("settings.audio.lyrics.customServer.url.placeholder"),
                    onCommit = {
                        val url = SessionManager.normalizeServerUrl(serverUrl)
                        if (url.isNotEmpty() && !SessionManager.isValidServerUrl(url)) {
                            graph.toaster.error(invalidUrl)
                        } else {
                            serverUrl = url
                            updateLyrics { it.copy(customServerUrl = url) }
                        }
                    },
                )
            }
            item {
                FieldSetting(
                    title = t("settings.audio.lyrics.customServer.password.label"),
                    info = t("settings.audio.lyrics.customServer.password.info"),
                    value = serverPassword,
                    onValueChange = { serverPassword = it },
                    placeholder = t("settings.audio.lyrics.customServer.password.placeholder"),
                    secret = true,
                    onCommit = { updateLyrics { it.copy(customServerPassword = serverPassword) } },
                )
            }
        }

        settingsSection(
            key = "history",
            title = strings.t("settings.audio.history.group"),
            description = strings.t("settings.audio.history.description"),
        ) {
            item {
                SliderSetting(
                    title = t("settings.audio.history.maxSize.label"),
                    info = t("settings.audio.history.maxSize.info"),
                    value = settings.playHistoryMaxSize,
                    onValueChange = { size -> graph.settings.update { it.copy(playHistoryMaxSize = size) } },
                    range = HISTORY_RANGE,
                    step = HISTORY_STEP,
                )
            }
        }
    }
}

/** The lyric sources in the order they are asked, to be dragged into another one. */
@Composable
private fun LyricsSourcePriority(order: List<LyricsSource>, onReorder: (List<LyricsSource>) -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        SettingText(
            title = t("settings.audio.lyrics.source.label"),
            info = t("settings.audio.lyrics.source.info"),
            modifier = Modifier.padding(bottom = 10.dp),
        )
        ReorderableColumn(
            items = order,
            rowHeight = SourceRowHeight,
            onMove = { from, to ->
                onReorder(order.toMutableList().apply { add(to, removeAt(from)) })
            },
        ) { index, source, handle, lifted ->
            val name = t("settings.audio.lyrics.source.${source.name.lowercase()}")
            Surface(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(vertical = 3.dp),
                shape = MaterialTheme.shapes.medium,
                color = MaterialTheme.colorScheme.surfaceContainerHighest,
                shadowElevation = if (lifted) 6.dp else 0.dp,
            ) {
                Row(
                    modifier = Modifier.padding(start = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "${index + 1}.",
                        style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(24.dp),
                    )
                    Text(
                        text = name,
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(
                        Icons.Rounded.DragHandle,
                        contentDescription = t("settings.audio.lyrics.source.dragHandle", "source" to name),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = handle
                            .size(SourceRowHeight - 6.dp)
                            .padding(12.dp),
                    )
                }
            }
        }
    }
}
