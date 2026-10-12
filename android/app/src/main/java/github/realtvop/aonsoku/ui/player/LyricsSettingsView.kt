package github.realtvop.aonsoku.ui.player

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.lyrics.LyricsCandidate
import github.realtvop.aonsoku.data.lyrics.LyricsRepository
import github.realtvop.aonsoku.data.runSuspendCatching
import github.realtvop.aonsoku.i18n.t
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

private val PreviewHeight = 208.dp
private val EmptyStateHeight = 192.dp
private const val CARD_ALPHA = 0.08f
private const val PREVIEW_ALPHA = 0.06f

/** "+0.3s"; positive shows the lyrics later. */
internal fun formatLyricsOffset(seconds: Double): String {
    val tenths = (seconds * 10).roundToInt()
    val sign = if (tenths > 0) "+" else if (tenths < 0) "-" else ""
    return String.format(Locale.ROOT, "%s%d.%ds", sign, abs(tenths) / 10, abs(tenths) % 10)
}

/**
 * What the user decides about the lyrics of the song that is playing: none at
 * all, a timing offset, or one of the entries a custom lyrics server offers.
 * [onChosen] runs once an entry was picked.
 */
@Composable
fun LyricsSettingsView(
    lyrics: PlayerLyrics,
    onChosen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val graph = LocalAppGraph.current
    val palette = LocalPlayerPalette.current
    val scope = rememberCoroutineScope()
    val settings by graph.settings.state.collectAsStateWithLifecycle()
    val song = lyrics.song
    val choice = lyrics.choice
    val disabled = lyrics.disabled
    val serverReady = settings.lyrics.customServerEnabled && settings.lyrics.customServerUrl.isNotBlank()
    val saveError = t("lyrics.customSelect.saveError")

    var title by rememberSaveable(song?.id) { mutableStateOf(song?.title.orEmpty()) }
    var artist by rememberSaveable(song?.id) { mutableStateOf(song?.artist.orEmpty()) }
    // What was last searched for, as title and artist.
    var search by rememberSaveable(song?.id) { mutableStateOf(title to artist) }

    // Null while the server is asked.
    var candidates by remember { mutableStateOf<List<LyricsCandidate>?>(null) }
    LaunchedEffect(
        song?.id,
        search,
        serverReady,
        settings.lyrics.customServerUrl,
        settings.lyrics.customServerPassword,
    ) {
        candidates = null
        val searchable = song != null && serverReady && (search.first.isNotBlank() || search.second.isNotBlank())
        candidates = if (searchable) graph.lyrics.candidates(search.first, search.second) else emptyList()
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(key = "header") {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = t("lyrics.customSelect.title"),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = if (song != null) {
                            t("lyrics.customSelect.subtitle", "title" to song.title, "artist" to song.artist)
                        } else {
                            t("player.noSongPlaying")
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = palette.muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.width(12.dp))
                PlayerPill(
                    icon = if (disabled) Icons.Rounded.Visibility else Icons.Rounded.VisibilityOff,
                    label = t(
                        if (disabled) "lyrics.customSelect.lyricsDisabled" else "lyrics.customSelect.disableLyrics",
                    ),
                    active = disabled,
                    enabled = song != null,
                    onClick = {
                        if (song != null) {
                            scope.launch {
                                runSuspendCatching { graph.lyrics.setDisabled(song, !disabled) }
                                    .onFailure { graph.toaster.error(saveError) }
                            }
                        }
                    },
                )
            }
        }

        if (song != null && serverReady) {
            item(key = "search") {
                val focus = LocalFocusManager.current
                val submit = {
                    search = title.trim() to artist.trim()
                    focus.clearFocus()
                }
                SettingsCard {
                    SearchField(
                        value = title,
                        onValueChange = { title = it },
                        label = t("lyrics.customSelect.searchTitle"),
                        onSearch = submit,
                    )
                    SearchField(
                        value = artist,
                        onValueChange = { artist = it },
                        label = t("lyrics.customSelect.searchArtist"),
                        onSearch = submit,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = if (choice != null && choice.key.isNotEmpty() && !disabled) {
                                t(
                                    "lyrics.customSelect.currentSelection",
                                    "title" to (choice.title ?: song.title),
                                    "artist" to (choice.artist ?: song.artist),
                                )
                            } else {
                                ""
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = palette.faint,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(1f)
                                .padding(end = 12.dp),
                        )
                        FilledPlayerButton(
                            icon = Icons.Rounded.Search,
                            label = t("lyrics.customSelect.search"),
                            enabled = title.isNotBlank() || artist.isNotBlank(),
                            onClick = submit,
                        )
                    }
                }
            }
        }

        if (song != null) {
            item(key = "offset") {
                val offset = choice?.offset ?: 0.0
                val setOffset = { seconds: Double -> scope.launch { graph.lyrics.setOffset(song, seconds) } }
                SettingsCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = t("lyrics.customSelect.offsetLabel"),
                            style = MaterialTheme.typography.labelLarge,
                            color = palette.muted,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = formatLyricsOffset(offset),
                            style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
                            modifier = Modifier.padding(end = 12.dp),
                        )
                        PlayerPill(
                            icon = Icons.Rounded.RestartAlt,
                            label = t("lyrics.customSelect.offsetReset"),
                            active = false,
                            enabled = !disabled && offset != 0.0,
                            onClick = { setOffset(0.0) },
                        )
                    }
                    PlayerSlider(
                        value = offset.toFloat(),
                        onValueChange = { setOffset(it.toDouble()) },
                        onValueChangeFinished = { setOffset(it.toDouble()) },
                        label = t("lyrics.customSelect.offsetLabel"),
                        valueRange = LyricsRepository.OFFSET_MIN.toFloat()..LyricsRepository.OFFSET_MAX.toFloat(),
                        enabled = !disabled,
                        valueText = { formatLyricsOffset(it.toDouble()) },
                        modifier = Modifier.padding(top = 4.dp),
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = PlayerSliderInset),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        val style = MaterialTheme.typography.labelSmall
                        Text(formatLyricsOffset(LyricsRepository.OFFSET_MIN), style = style, color = palette.faint)
                        Text(t("lyrics.customSelect.offsetHint"), style = style, color = palette.faint)
                        Text(formatLyricsOffset(LyricsRepository.OFFSET_MAX), style = style, color = palette.faint)
                    }
                }
            }
        }

        val found = candidates
        when {
            song == null -> item(key = "empty") { EmptyState(t("lyrics.customSelect.noSong")) }
            !serverReady -> item(key = "empty") { EmptyState(t("lyrics.customSelect.serverDisabled")) }
            found == null -> item(key = "empty") { EmptyState(t("fullscreen.loadingLyrics")) }
            found.isEmpty() -> item(key = "empty") { EmptyState(t("lyrics.customSelect.empty")) }
            else -> itemsIndexed(found, key = { index, candidate -> candidate.key(index) }) { index, candidate ->
                CandidateCard(
                    candidate = candidate,
                    title = candidate.title?.takeIf { it.isNotEmpty() } ?: song.title,
                    artist = candidate.artist?.takeIf { it.isNotEmpty() } ?: song.artist,
                    selected = candidate.key(index) == choice?.key,
                    onSelect = {
                        scope.launch {
                            runSuspendCatching {
                                graph.lyrics.choose(song, candidate, index, search.first, search.second)
                            }.onSuccess { onChosen() }.onFailure { graph.toaster.error(saveError) }
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun SettingsCard(content: @Composable ColumnScope.() -> Unit) {
    val palette = LocalPlayerPalette.current
    val shape = MaterialTheme.shapes.large
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.content.copy(alpha = CARD_ALPHA))
            .border(BorderStroke(1.dp, palette.outline), shape)
            .padding(12.dp),
        content = content,
    )
}

@Composable
private fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    onSearch: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalPlayerPalette.current
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { onSearch() }),
        shape = MaterialTheme.shapes.medium,
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = palette.content,
            unfocusedTextColor = palette.content,
            focusedContainerColor = Color.Transparent,
            unfocusedContainerColor = Color.Transparent,
            cursorColor = palette.content,
            selectionColors = TextSelectionColors(
                handleColor = palette.content,
                backgroundColor = palette.content.copy(alpha = 0.3f),
            ),
            focusedBorderColor = palette.muted,
            unfocusedBorderColor = palette.outline,
            focusedLabelColor = palette.content,
            unfocusedLabelColor = palette.muted,
        ),
    )
}

/** The one filled button of a card, in the colors of the play button. */
@Composable
private fun FilledPlayerButton(
    icon: ImageVector?,
    label: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    filled: Boolean = true,
) {
    val palette = LocalPlayerPalette.current
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = CircleShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (filled) palette.playContainer else palette.container,
            contentColor = if (filled) palette.playContent else palette.content,
            disabledContainerColor = palette.content.copy(alpha = 0.12f),
            disabledContentColor = palette.content.copy(alpha = 0.38f),
        ),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(text = label, style = MaterialTheme.typography.labelLarge, maxLines = 1)
    }
}

@Composable
private fun CandidateCard(
    candidate: LyricsCandidate,
    title: String,
    artist: String,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    val palette = LocalPlayerPalette.current
    SettingsCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (candidate.hasRomaji) RomajiBadge()
                }
                Text(
                    text = artist,
                    style = MaterialTheme.typography.bodyMedium,
                    color = palette.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(12.dp))
            FilledPlayerButton(
                icon = Icons.Rounded.Check.takeIf { selected },
                label = t(if (selected) "lyrics.customSelect.selected" else "lyrics.customSelect.select"),
                filled = !selected,
                onClick = onSelect,
            )
        }
        val id = candidate.id
        if (!id.isNullOrEmpty()) {
            Text(
                text = t("lyrics.customSelect.lyricsId", "id" to id),
                style = MaterialTheme.typography.labelSmall,
                color = palette.faint,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Box(
            modifier = Modifier
                .padding(top = 8.dp)
                .fillMaxWidth()
                .height(PreviewHeight)
                .clip(MaterialTheme.shapes.medium)
                .background(palette.content.copy(alpha = PREVIEW_ALPHA))
                .border(BorderStroke(1.dp, palette.outline), MaterialTheme.shapes.medium)
                .verticalScroll(rememberScrollState())
                .padding(12.dp),
        ) {
            Text(
                text = candidate.lyrics?.trim().orEmpty().ifEmpty { t("lyrics.customSelect.noPreview") },
                style = MaterialTheme.typography.bodyMedium,
                color = palette.content.copy(alpha = 0.75f),
            )
        }
    }
}

@Composable
private fun RomajiBadge() {
    val palette = LocalPlayerPalette.current
    Row(
        modifier = Modifier
            .padding(start = 8.dp)
            .clip(CircleShape)
            .background(palette.container)
            .padding(horizontal = 8.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Rounded.Translate, contentDescription = null, modifier = Modifier.size(12.dp))
        Text(text = t("lyrics.customSelect.hasRomaji"), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun EmptyState(message: String) {
    val palette = LocalPlayerPalette.current
    SettingsCard {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = EmptyStateHeight),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        ) {
            Icon(
                Icons.Rounded.MusicNote,
                contentDescription = null,
                tint = palette.muted,
                modifier = Modifier.size(32.dp),
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodyLarge,
                color = palette.muted,
                textAlign = TextAlign.Center,
            )
        }
    }
}
