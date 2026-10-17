package github.realtvop.aonsoku.ui.detail

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.node.Ref
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.data.model.FeaturedArtist
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.theme.blend
import github.realtvop.aonsoku.theme.contentColor
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.averageColor
import github.realtvop.aonsoku.ui.components.subPageTopPadding
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay
import kotlin.math.roundToInt

/** One entry of a header info line. [onClick] turns it into a link. */
@Immutable
data class HeaderBadge(val text: String, val onClick: (() -> Unit)? = null)

/**
 * What a detail header shares with the page around it: the tint taken from
 * the artwork, and where the in-page title ends, which decides when the page
 * bar starts showing the title.
 */
@Stable
class DetailHeaderState {
    /** Average color of the artwork; null until it has loaded (or without artwork). */
    var accent: Color? by mutableStateOf(null)

    /** Distance from the top of the header to the bottom of its title, in pixels. */
    var titleBottom: Int by mutableIntStateOf(Int.MAX_VALUE)
}

/** Colors derived from the artwork tint, animated while the artwork loads. */
@Immutable
data class DetailColors(
    val accent: Color,
    /** Content color on the tinted header. */
    val content: Color,
    /** Content color on the strip that fades the tint into the page. */
    val stripContent: Color,
)

@Composable
fun rememberDetailColors(state: DetailHeaderState): DetailColors {
    val background = MaterialTheme.colorScheme.background
    val onBackground = MaterialTheme.colorScheme.onBackground
    val spec = MaterialTheme.motionScheme.slowEffectsSpec<Color>()
    val tint = state.accent
    val accent by animateColorAsState(tint ?: background, spec, label = "detailAccent")
    val content by animateColorAsState(
        targetValue = tint?.blend(background, HEADER_TEXT_OVERLAY)?.contentColor() ?: onBackground,
        animationSpec = spec,
        label = "detailContent",
    )
    val stripContent by animateColorAsState(
        targetValue = tint?.blend(background, STRIP_ICON_OVERLAY)?.contentColor() ?: onBackground,
        animationSpec = spec,
        label = "detailStripContent",
    )
    return DetailColors(accent, content, stripContent)
}

/** True once the title of the header has scrolled under the page bar. */
@Composable
fun rememberDetailCollapsed(listState: LazyListState, header: DetailHeaderState): State<Boolean> {
    val barBottom = with(LocalDensity.current) { subPageTopPadding().roundToPx() }
    return remember(listState, header, barBottom) {
        derivedStateOf {
            listState.firstVisibleItemIndex > 0 ||
                listState.firstVisibleItemScrollOffset > header.titleBottom - barBottom
        }
    }
}

/**
 * Header of an album, artist, playlist, or favorites page: the artwork on a
 * background tinted with its average color, the title, and info lines. It
 * runs under the status bar and the page bar.
 */
@Composable
fun DetailHeader(
    state: DetailHeaderState,
    type: String,
    title: String,
    modifier: Modifier = Modifier,
    art: CoverArt = CoverArt(emptyList()),
    kind: CoverKind = CoverKind.Album,
    /** Shown instead of artwork, for pages that have none (favorites). */
    icon: ImageVector? = null,
    /** Artists linked above the artwork. */
    artists: List<FeaturedArtist> = emptyList(),
    onArtist: (FeaturedArtist) -> Unit = {},
    subtitle: String? = null,
    badges: List<HeaderBadge> = emptyList(),
    secondaryBadges: List<HeaderBadge> = emptyList(),
) {
    val overlays = LocalOverlays.current
    val background = MaterialTheme.colorScheme.background
    val colors = rememberDetailColors(state)
    val headerCoordinates = remember { Ref<LayoutCoordinates>() }
    val brush = Brush.verticalGradient(
        0f to colors.accent.blend(background, HEADER_TOP_OVERLAY),
        0.5f to colors.accent.blend(background, HEADER_MID_OVERLAY),
        1f to colors.accent.blend(background, HEADER_BOTTOM_OVERLAY),
    )

    Column(
        modifier = modifier
            .fillMaxWidth()
            .onGloballyPositioned { headerCoordinates.value = it }
            .background(brush)
            .padding(
                start = 24.dp,
                end = 24.dp,
                top = subPageTopPadding() + 4.dp,
                bottom = 12.dp,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CompositionLocalProvider(LocalContentColor provides colors.content) {
            if (artists.isNotEmpty()) ArtistLinks(artists, onArtist)

            val shape = if (kind == CoverKind.Artist) CircleShape else MaterialTheme.shapes.medium
            if (icon != null) {
                Box(
                    modifier = Modifier
                        .size(ArtworkSize)
                        .shadow(ArtworkElevation, shape)
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = icon,
                        contentDescription = null,
                        modifier = Modifier.size(88.dp),
                        tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                    )
                }
            } else {
                Box(
                    modifier = Modifier
                        .size(ArtworkSize)
                        .shadow(ArtworkElevation, shape)
                        .clickable(enabled = !art.isEmpty) {
                            overlays.show(Overlay.Artwork(art, kind, title))
                        },
                ) {
                    CoverImage(
                        art = art,
                        modifier = Modifier.fillMaxSize(),
                        kind = kind,
                        shape = shape,
                        contentDescription = title,
                        onBitmap = { bitmap -> averageColor(bitmap)?.let { state.accent = it } },
                    )
                }
            }

            Spacer(Modifier.height(14.dp))
            Text(
                text = type,
                style = MaterialTheme.typography.labelSmall,
                color = LocalContentColor.current.copy(alpha = 0.9f),
            )
            Text(
                text = title,
                modifier = Modifier
                    .padding(top = 2.dp)
                    .onGloballyPositioned { coordinates ->
                        val header = headerCoordinates.value
                        if (header != null && header.isAttached && coordinates.isAttached) {
                            val bottom = Offset(0f, coordinates.size.height.toFloat())
                            state.titleBottom =
                                header.localPositionOf(coordinates, bottom).y.roundToInt()
                        }
                    },
                style = if (title.length > LONG_TITLE_LENGTH) {
                    MaterialTheme.typography.titleLarge
                } else {
                    MaterialTheme.typography.headlineSmall
                },
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(6.dp))

            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    modifier = Modifier.padding(bottom = 2.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = LocalContentColor.current.copy(alpha = 0.8f),
                    textAlign = TextAlign.Center,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            BadgeLine(badges)
            BadgeLine(secondaryBadges)
        }
    }
}

@Composable
private fun ArtistLinks(artists: List<FeaturedArtist>, onArtist: (FeaturedArtist) -> Unit) {
    FlowRow(
        modifier = Modifier.padding(bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        artists.take(MAX_HEADER_ARTISTS).forEach { artist ->
            val linked = artist.id.isNotEmpty()
            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .clickable(enabled = linked) { onArtist(artist) }
                    .padding(start = 3.dp, top = 3.dp, bottom = 3.dp, end = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (linked) {
                    CoverImage(
                        art = CoverArt(artist.id),
                        modifier = Modifier.size(24.dp),
                        kind = CoverKind.Artist,
                        shape = CircleShape,
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    text = artist.name,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun BadgeLine(badges: List<HeaderBadge>) {
    if (badges.isEmpty()) return
    val color = LocalContentColor.current.copy(alpha = 0.8f)
    FlowRow(
        horizontalArrangement = Arrangement.Center,
        itemVerticalAlignment = Alignment.CenterVertically,
    ) {
        badges.forEachIndexed { index, badge ->
            if (index > 0) {
                Text(
                    text = "•",
                    modifier = Modifier.padding(horizontal = 6.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    color = color,
                )
            }
            val link = badge.onClick
            Text(
                text = badge.text,
                modifier = if (link != null) {
                    Modifier
                        .clip(MaterialTheme.shapes.extraSmall)
                        .clickable(onClick = link)
                } else {
                    Modifier
                },
                style = MaterialTheme.typography.bodyMedium,
                color = color,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Shuffle, play, and "more" below a [DetailHeader], on a strip that fades the
 * header tint into the page. A missing side action keeps its place so the
 * play button stays centered.
 */
@Composable
fun DetailActions(
    state: DetailHeaderState,
    name: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onPlay: (() -> Unit)? = null,
    onShuffle: (() -> Unit)? = null,
    onMore: (() -> Unit)? = null,
) {
    val background = MaterialTheme.colorScheme.background
    val colors = rememberDetailColors(state)
    val brush = Brush.verticalGradient(
        listOf(colors.accent.blend(background, HEADER_BOTTOM_OVERLAY), background),
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 32.dp)
            .background(brush),
        contentAlignment = Alignment.TopCenter,
    ) {
        if (onPlay == null) return@Box
        Row(
            modifier = Modifier.padding(top = 12.dp, bottom = 20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CompositionLocalProvider(LocalContentColor provides colors.stripContent) {
                SideAction(
                    icon = Icons.Rounded.Shuffle,
                    description = t("playlist.buttons.shuffle", "name" to name),
                    onClick = onShuffle,
                    enabled = enabled,
                )
                FilledIconButton(
                    onClick = onPlay,
                    shapes = IconButtonDefaults.shapes(),
                    modifier = Modifier.size(
                        IconButtonDefaults.mediumContainerSize(
                            IconButtonDefaults.IconButtonWidthOption.Wide,
                        ),
                    ),
                    enabled = enabled,
                ) {
                    Icon(
                        Icons.Rounded.PlayArrow,
                        contentDescription = t("playlist.buttons.play", "name" to name),
                        modifier = Modifier.size(IconButtonDefaults.mediumIconSize),
                    )
                }
                SideAction(
                    icon = Icons.Rounded.MoreVert,
                    description = t("playlist.buttons.options", "name" to name),
                    onClick = onMore,
                    enabled = true,
                )
            }
        }
    }
}

@Composable
private fun SideAction(
    icon: ImageVector,
    description: String,
    onClick: (() -> Unit)?,
    enabled: Boolean,
) {
    if (onClick == null) {
        Spacer(Modifier.size(SideActionSize))
        return
    }
    IconButton(
        onClick = onClick,
        shapes = IconButtonDefaults.shapes(),
        modifier = Modifier.size(SideActionSize),
        enabled = enabled,
    ) {
        Icon(icon, contentDescription = description)
    }
}

private val ArtworkSize = 168.dp
private val ArtworkElevation = 14.dp
private val SideActionSize = 48.dp

/** Share of the page background laid over the tint at the top, middle, and bottom. */
private const val HEADER_TOP_OVERLAY = 0.20f
private const val HEADER_MID_OVERLAY = 0.35f
private const val HEADER_BOTTOM_OVERLAY = 0.50f

/** Overlay at the height of the header text and of the action icons. */
private const val HEADER_TEXT_OVERLAY = 0.40f
private const val STRIP_ICON_OVERLAY = 0.70f

private const val MAX_HEADER_ARTISTS = 4
private const val LONG_TITLE_LENGTH = 36
