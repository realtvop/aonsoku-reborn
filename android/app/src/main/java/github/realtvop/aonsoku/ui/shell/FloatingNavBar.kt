package github.realtvop.aonsoku.ui.shell

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.LibraryMusic
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.navigation.TopLevelTab

/** Height of the floating bar surfaces, used to pad scrolling content. */
val FloatingNavBarHeight = 64.dp

/**
 * Floating bottom navigation: a pill holding the Home and Library tabs with a
 * detached circular Search action beside it.
 */
@Composable
fun FloatingNavBar(
    currentTab: TopLevelTab,
    onSelect: (TopLevelTab) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
            tonalElevation = 3.dp,
            shadowElevation = 8.dp,
        ) {
            Row(
                modifier = Modifier
                    .height(FloatingNavBarHeight)
                    .padding(6.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                NavPill(
                    label = t("sidebar.home"),
                    icon = Icons.Outlined.Home,
                    selectedIcon = Icons.Rounded.Home,
                    selected = currentTab == TopLevelTab.Home,
                    onClick = { onSelect(TopLevelTab.Home) },
                )
                NavPill(
                    label = t("sidebar.library"),
                    icon = Icons.Outlined.LibraryMusic,
                    selectedIcon = Icons.Rounded.LibraryMusic,
                    selected = currentTab == TopLevelTab.Library,
                    onClick = { onSelect(TopLevelTab.Library) },
                )
            }
        }

        val searchSelected = currentTab == TopLevelTab.Search
        val searchContainer by animateColorAsState(
            targetValue = if (searchSelected) {
                MaterialTheme.colorScheme.primary
            } else {
                MaterialTheme.colorScheme.surfaceContainerHigh
            },
            animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
            label = "searchContainer",
        )
        val searchContent by animateColorAsState(
            targetValue = if (searchSelected) {
                MaterialTheme.colorScheme.onPrimary
            } else {
                MaterialTheme.colorScheme.onSurface
            },
            animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
            label = "searchContent",
        )
        val searchInteraction = remember { MutableInteractionSource() }
        val searchLabel = t("sidebar.miniSearch")
        Surface(
            onClick = { onSelect(TopLevelTab.Search) },
            modifier = Modifier
                .size(FloatingNavBarHeight)
                .pressScale(searchInteraction)
                .semantics { contentDescription = searchLabel },
            shape = CircleShape,
            color = searchContainer,
            contentColor = searchContent,
            tonalElevation = 3.dp,
            shadowElevation = 8.dp,
            interactionSource = searchInteraction,
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.Search, contentDescription = null)
            }
        }
    }
}

@Composable
private fun NavPill(
    label: String,
    icon: ImageVector,
    selectedIcon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val container by animateColorAsState(
        targetValue = if (selected) {
            MaterialTheme.colorScheme.secondaryContainer
        } else {
            MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0f)
        },
        animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "navPillContainer",
    )
    val content by animateColorAsState(
        targetValue = if (selected) {
            MaterialTheme.colorScheme.onSecondaryContainer
        } else {
            MaterialTheme.colorScheme.onSurfaceVariant
        },
        animationSpec = MaterialTheme.motionScheme.defaultEffectsSpec(),
        label = "navPillContent",
    )
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxHeight()
            .pressScale(interaction)
            .clip(CircleShape)
            .background(container)
            .selectable(
                selected = selected,
                onClick = onClick,
                role = Role.Tab,
                interactionSource = interaction,
                indication = ripple(),
            )
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = if (selected) selectedIcon else icon,
            contentDescription = null,
            tint = content,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = content,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Expressive press feedback: the element springs slightly smaller while held. */
@Composable
fun Modifier.pressScale(
    interactionSource: MutableInteractionSource,
    pressedScale: Float = 0.94f,
): Modifier {
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) pressedScale else 1f,
        animationSpec = MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "pressScale",
    )
    return graphicsLayer {
        scaleX = scale
        scaleY = scale
    }
}
