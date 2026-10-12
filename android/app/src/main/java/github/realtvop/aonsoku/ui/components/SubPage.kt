package github.realtvop.aonsoku.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.theme.blend
import github.realtvop.aonsoku.theme.contentColor
import github.realtvop.aonsoku.ui.navigation.LocalNavigator
import github.realtvop.aonsoku.ui.shell.LocalFloatingBarsPadding

/** Height of the bar of a sub page, excluding the status bar. */
val SubPageBarHeight = 48.dp

/** Top inset a sub page leaves for its bar when the content does not run under it. */
@Composable
fun subPageTopPadding(): Dp =
    WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + SubPageBarHeight

/** Content padding of a list page: below its bar and above the floating navigation. */
@Composable
fun subPageContentPadding(): PaddingValues = PaddingValues(
    top = subPageTopPadding(),
    bottom = LocalFloatingBarsPadding.current + 8.dp,
)

/** Like [subPageContentPadding] for detail pages whose header runs under the bar. */
@Composable
fun detailPageContentPadding(): PaddingValues =
    PaddingValues(bottom = LocalFloatingBarsPadding.current + 8.dp)

/**
 * Bar of a pushed page: a back button, the page title once the in-page title
 * has scrolled away, and optional actions. On detail pages it floats over
 * the artwork header and takes the [accent] tint once it becomes solid.
 */
@Composable
fun SubPageTopBar(
    title: String,
    collapsed: Boolean,
    modifier: Modifier = Modifier,
    accent: Color? = null,
    /** Content color while the bar floats over the page (not [collapsed]). */
    floatingContentColor: Color = MaterialTheme.colorScheme.onBackground,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val navigator = LocalNavigator.current
    val background = MaterialTheme.colorScheme.background
    val solid = if (accent != null) background.blend(accent, 0.35f) else background
    val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Color>()
    val container by animateColorAsState(
        targetValue = if (collapsed) solid.copy(alpha = 0.96f) else solid.copy(alpha = 0f),
        animationSpec = effects,
        label = "subPageBarContainer",
    )
    val content by animateColorAsState(
        targetValue = when {
            !collapsed -> floatingContentColor
            accent != null -> solid.contentColor()
            else -> MaterialTheme.colorScheme.onBackground
        },
        animationSpec = effects,
        label = "subPageBarContent",
    )
    val titleAlpha by animateFloatAsState(
        targetValue = if (collapsed) 1f else 0f,
        animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "subPageBarTitle",
    )

    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(container)
            .statusBarsPadding()
            .height(SubPageBarHeight)
            .padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(LocalContentColor provides content) {
            IconButton(onClick = { onBack?.invoke() ?: navigator.back() }) {
                Icon(
                    Icons.AutoMirrored.Rounded.ArrowBack,
                    contentDescription = t("navigation.back"),
                )
            }
            Text(
                text = title,
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 4.dp)
                    .graphicsLayer { alpha = titleAlpha },
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            actions()
        }
    }
}

/** Large in-page title of a list page with an optional count and actions. */
@Composable
fun PageTitle(
    title: String,
    modifier: Modifier = Modifier,
    count: String? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 8.dp, top = 8.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.headlineMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (count != null) {
                Text(
                    text = count,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        actions()
    }
}

/** True once the first item (the in-page title) has scrolled out of view. */
@Composable
fun rememberTitleCollapsed(state: LazyListState, thresholdPx: Int = 96): State<Boolean> =
    remember(state, thresholdPx) {
        derivedStateOf {
            state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > thresholdPx
        }
    }

@Composable
fun rememberTitleCollapsed(state: LazyGridState, thresholdPx: Int = 96): State<Boolean> =
    remember(state, thresholdPx) {
        derivedStateOf {
            state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > thresholdPx
        }
    }
