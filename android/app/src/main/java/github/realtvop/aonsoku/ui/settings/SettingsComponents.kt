package github.realtvop.aonsoku.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.SliderState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.ui.components.PageTitle
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.rememberTitleCollapsed
import github.realtvop.aonsoku.ui.components.subPageContentPadding
import kotlin.math.roundToInt

private val PageInset = 16.dp
private val GroupCorner = 20.dp
private val SegmentCorner = 4.dp
private val SegmentGap = 2.dp
private val RowMinHeight = 56.dp
private const val MAX_SLIDER_MARKS = 12

/** A settings page: its title, then sections, under the bar of a pushed page. */
@Composable
fun SettingsPage(title: String, content: LazyListScope.() -> Unit) {
    val listState = rememberLazyListState()
    val collapsed by rememberTitleCollapsed(listState)
    Box(modifier = Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .imePadding(),
            contentPadding = subPageContentPadding(),
        ) {
            item(key = "title") { PageTitle(title = title) }
            content()
        }
        SubPageTopBar(title = title, collapsed = collapsed)
    }
}

/** A titled group of settings, as one item of a [SettingsPage]. */
fun LazyListScope.settingsSection(
    key: String,
    title: String? = null,
    description: String? = null,
    content: SettingsGroupScope.() -> Unit,
) {
    item(key = key) {
        Column(
            modifier = Modifier
                .padding(horizontal = PageInset)
                .padding(bottom = 24.dp),
        ) {
            SectionHeader(title, description)
            SettingsGroup(content = content)
        }
    }
}

@Composable
fun SectionHeader(title: String?, description: String?, modifier: Modifier = Modifier) {
    if (title == null && description == null) return
    Column(
        modifier = modifier
            .padding(horizontal = 4.dp)
            .padding(bottom = 10.dp),
    ) {
        if (title != null) {
            Text(text = title, style = MaterialTheme.typography.titleMedium)
        }
        if (description != null) {
            Text(
                text = description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

/** Collects the rows of a [SettingsGroup]; rows that depend on a setting are simply left out. */
class SettingsGroupScope internal constructor() {
    internal val rows = ArrayList<Pair<Any?, @Composable () -> Unit>>()

    /** [key] keeps the state of a row that moves when rows before it come and go. */
    fun item(key: Any? = null, content: @Composable () -> Unit) {
        rows += key to content
    }
}

/**
 * Rows on surfaces of their own that read as one group: only the outer corners
 * of the first and the last row are fully rounded.
 */
@Composable
fun SettingsGroup(modifier: Modifier = Modifier, content: SettingsGroupScope.() -> Unit) {
    val rows = SettingsGroupScope().apply(content).rows
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(SegmentGap)) {
        rows.forEachIndexed { index, (rowKey, row) ->
            key(rowKey ?: index) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    shape = segmentShape(index, rows.size),
                    color = MaterialTheme.colorScheme.surfaceContainer,
                ) {
                    row()
                }
            }
        }
    }
}

private fun segmentShape(index: Int, count: Int): Shape {
    val top = if (index == 0) GroupCorner else SegmentCorner
    val bottom = if (index == count - 1) GroupCorner else SegmentCorner
    return RoundedCornerShape(topStart = top, topEnd = top, bottomStart = bottom, bottomEnd = bottom)
}

/** A row with a title, an optional explanation below it, and something at its end. */
@Composable
fun SettingRow(
    title: String,
    modifier: Modifier = Modifier,
    info: String? = null,
    icon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .heightIn(min = RowMinHeight)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.width(16.dp))
        }
        SettingText(title = title, info = info, modifier = Modifier.weight(1f))
        if (trailing != null) {
            Spacer(Modifier.width(16.dp))
            trailing()
        }
    }
}

@Composable
fun SettingText(title: String, info: String?, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Text(text = title, style = MaterialTheme.typography.bodyLarge)
        if (info != null) {
            Text(
                text = info,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
fun SwitchSetting(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    info: String? = null,
    enabled: Boolean = true,
) {
    SettingRow(
        title = title,
        info = info,
        modifier = Modifier.toggleable(
            value = checked,
            enabled = enabled,
            role = Role.Switch,
            onValueChange = onCheckedChange,
        ),
        trailing = { Switch(checked = checked, onCheckedChange = null, enabled = enabled) },
    )
}

/** Something the app reports and no setting of the page changes. */
@Composable
fun ValueSetting(title: String, value: String, info: String? = null) {
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        SettingText(title = title, info = info, modifier = Modifier.padding(bottom = 10.dp))
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = MaterialTheme.shapes.medium,
            color = MaterialTheme.colorScheme.surfaceContainerHighest,
        ) {
            Text(
                text = value,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            )
        }
    }
}

/** A whole number picked on a slider, with the value next to the title. */
@Composable
fun SliderSetting(
    title: String,
    value: Int,
    onValueChange: (Int) -> Unit,
    range: IntRange,
    step: Int = 1,
    info: String? = null,
    valueLabel: (Int) -> String = { it.toString() },
) {
    val state = remember(range, step) {
        SliderState(
            value.toFloat(),
            ((range.last - range.first) / step - 1).coerceAtLeast(0),
            range.first.toFloat()..range.last.toFloat(),
        )
    }
    // The setting may change elsewhere; a drag in progress keeps the thumb.
    LaunchedEffect(value) {
        if (!state.isDragging) state.value = value.toFloat()
    }
    val shown = state.value.roundToInt()
    // Marks for every value only read as marks while there are few of them.
    val colors = if ((range.last - range.first) / step > MAX_SLIDER_MARKS) {
        SliderDefaults.colors(activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent)
    } else {
        SliderDefaults.colors()
    }
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SettingText(title = title, info = info, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(16.dp))
            Text(
                text = valueLabel(shown),
                style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                color = MaterialTheme.colorScheme.primary,
            )
        }
        Slider(
            state = state,
            onValueChange = { target ->
                state.value = target
                val snapped = range.first + ((target - range.first) / step).roundToInt() * step
                if (snapped != value) onValueChange(snapped.coerceIn(range.first, range.last))
            },
            modifier = Modifier.semantics { contentDescription = title },
            colors = colors,
        )
    }
}

/** One of a few options, picked on a row of joined buttons. */
@Composable
fun <T> ChoiceSetting(
    title: String?,
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    info: String? = null,
    icons: Map<T, ImageVector> = emptyMap(),
) {
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        if (title != null) {
            SettingText(title = title, info = info, modifier = Modifier.padding(bottom = 10.dp))
        }
        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
            options.forEachIndexed { index, (option, label) ->
                SegmentedButton(
                    selected = option == selected,
                    onClick = { onSelect(option) },
                    shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
                    icon = {
                        val icon = icons[option]
                        if (icon != null) {
                            Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
                        } else {
                            SegmentedButtonDefaults.Icon(active = option == selected)
                        }
                    },
                ) {
                    Text(text = label, maxLines = 1)
                }
            }
        }
    }
}

/**
 * A text setting. [onCommit] runs when editing ends: with the keyboard's
 * done action, or when the field loses the focus.
 */
@Composable
fun FieldSetting(
    title: String,
    value: String,
    onValueChange: (String) -> Unit,
    info: String? = null,
    placeholder: String? = null,
    enabled: Boolean = true,
    secret: Boolean = false,
    onCommit: () -> Unit = {},
) {
    val focus = LocalFocusManager.current
    var focused by remember { mutableStateOf(false) }
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        SettingText(title = title, info = info, modifier = Modifier.padding(bottom = 10.dp))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { state ->
                    if (focused && !state.isFocused) onCommit()
                    focused = state.isFocused
                }
                .semantics { contentDescription = title },
            enabled = enabled,
            singleLine = true,
            placeholder = placeholder?.let { text -> { Text(text, maxLines = 1) } },
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                autoCorrectEnabled = false,
                keyboardType = if (secret) KeyboardType.Password else KeyboardType.Uri,
                imeAction = ImeAction.Done,
            ),
            // Leaving the field commits, so done only has to let go of it.
            keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }),
            shape = MaterialTheme.shapes.medium,
        )
    }
}
