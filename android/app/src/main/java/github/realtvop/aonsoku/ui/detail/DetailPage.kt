package github.realtvop.aonsoku.ui.detail

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.SearchOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import github.realtvop.aonsoku.data.Loadable
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.ui.components.BrandIcons
import github.realtvop.aonsoku.ui.components.EmptyState
import github.realtvop.aonsoku.ui.components.PageLoading
import github.realtvop.aonsoku.ui.components.SubPageTopBar
import github.realtvop.aonsoku.ui.components.detailPageContentPadding
import github.realtvop.aonsoku.ui.components.htmlText
import github.realtvop.aonsoku.ui.components.linkify
import github.realtvop.aonsoku.ui.components.rememberLinkStyles

/**
 * Scrolling detail page whose first item is a [DetailHeader]. The page bar
 * floats over the header and turns solid, tinted, and titled once the header
 * title has scrolled away.
 */
@Composable
fun DetailPage(
    title: String,
    header: DetailHeaderState,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
    barActions: @Composable RowScope.() -> Unit = {},
    content: LazyListScope.() -> Unit,
) {
    val collapsed by rememberDetailCollapsed(listState, header)
    val colors = rememberDetailColors(header)
    Box(modifier = modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = detailPageContentPadding(),
            content = content,
        )
        SubPageTopBar(
            title = title,
            collapsed = collapsed,
            accent = header.accent,
            floatingContentColor = colors.content,
            actions = barActions,
        )
    }
}

/** A detail page whose content is still loading. */
@Composable
fun DetailLoading() {
    Box(modifier = Modifier.fillMaxSize()) {
        PageLoading()
        SubPageTopBar(title = "", collapsed = false)
    }
}

/** A detail page that could not be loaded: missing on the server, or offline. */
@Composable
fun DetailFailure(failure: Loadable.Failed) {
    Box(modifier = Modifier.fillMaxSize()) {
        when {
            failure.notFound -> EmptyState(
                title = t("error.notFound"),
                icon = Icons.Rounded.SearchOff,
                modifier = Modifier.align(Alignment.Center),
            )
            failure.offline -> EmptyState(
                title = t("offline.mode"),
                description = t("offline.disconnected"),
                icon = Icons.Rounded.CloudOff,
                modifier = Modifier.align(Alignment.Center),
            )
            else -> EmptyState(
                title = t("toast.server.error"),
                icon = Icons.Rounded.CloudOff,
                modifier = Modifier.align(Alignment.Center),
            )
        }
        SubPageTopBar(title = "", collapsed = false)
    }
}

/**
 * "About" card with the biography of an artist or the notes of an album.
 * Long texts start collapsed.
 */
@Composable
fun InfoPanel(
    name: String,
    html: String,
    modifier: Modifier = Modifier,
    lastFmUrl: String? = null,
    musicBrainzUrl: String? = null,
) {
    val styles = rememberLinkStyles()
    val text = remember(html, styles) { htmlText(html, styles) }
    if (text.isEmpty()) return

    val uriHandler = LocalUriHandler.current
    var expanded by rememberSaveable(html) { mutableStateOf(false) }
    var overflowing by remember(html) { mutableStateOf(false) }
    val shape = MaterialTheme.shapes.large
    val hasLinks = !lastFmUrl.isNullOrBlank() || !musicBrainzUrl.isNullOrBlank()

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            .animateContentSize(MaterialTheme.motionScheme.defaultSpatialSpec())
            .padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 12.dp),
    ) {
        Text(
            text = t("album.info.about", "name" to name),
            style = MaterialTheme.typography.titleLarge,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium.copy(lineHeight = 24.sp),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = if (expanded) Int.MAX_VALUE else COLLAPSED_INFO_LINES,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { if (!expanded) overflowing = it.hasVisualOverflow },
        )
        if (hasLinks || overflowing || expanded) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                lastFmUrl?.takeIf { it.isNotBlank() }?.let { url ->
                    IconButton(onClick = { runCatching { uriHandler.openUri(url) } }) {
                        Icon(
                            BrandIcons.LastFm,
                            contentDescription = t("album.info.lastfm"),
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
                musicBrainzUrl?.takeIf { it.isNotBlank() }?.let { url ->
                    IconButton(onClick = { runCatching { uriHandler.openUri(url) } }) {
                        Icon(
                            BrandIcons.MusicBrainz,
                            contentDescription = t("album.info.musicbrainz"),
                            modifier = Modifier.size(22.dp),
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                if (overflowing || expanded) {
                    TextButton(onClick = { expanded = !expanded }) {
                        Text(t(if (expanded) "generic.hideDetails" else "generic.showDetails"))
                    }
                }
            }
        } else {
            Spacer(Modifier.height(8.dp))
        }
    }
}

/** Free-form note of an album (the comment tag of its first track). */
@Composable
fun CommentCard(comment: String, modifier: Modifier = Modifier) {
    val styles = rememberLinkStyles()
    val text = remember(comment, styles) { linkify(comment.trim(), styles) }
    val shape = MaterialTheme.shapes.medium
    Text(
        text = text,
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            .padding(16.dp),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** Notice shown in place of a list that is not available right now. */
@Composable
fun NoticeCard(title: String, description: String, modifier: Modifier = Modifier) {
    val shape = MaterialTheme.shapes.medium
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceContainer)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            .padding(16.dp),
    ) {
        Text(text = title, style = MaterialTheme.typography.titleSmall)
        Spacer(Modifier.height(4.dp))
        Text(
            text = description,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private const val COLLAPSED_INFO_LINES = 5
