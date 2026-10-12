package github.realtvop.aonsoku.ui.player

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Radio
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.LocalAppGraph
import github.realtvop.aonsoku.data.image.CoverArt
import github.realtvop.aonsoku.i18n.t
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.theme.LikedColor
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.queueSongCoverArt
import github.realtvop.aonsoku.ui.overlays.LocalOverlays
import github.realtvop.aonsoku.ui.overlays.Overlay

private val ArtworkMaxSize = 480.dp

/** The "now playing" tab: album name, artwork, the song line, and the controls. */
@Composable
fun PlayingView(state: PlayerState, modifier: Modifier = Modifier) {
    val palette = LocalPlayerPalette.current
    val song = state.current?.takeIf { !state.isRadio }
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = song?.album.orEmpty(),
            style = MaterialTheme.typography.bodyMedium,
            color = palette.muted,
            maxLines = 1,
            modifier = Modifier
                .padding(top = 4.dp, bottom = 12.dp)
                .basicMarquee(),
        )
        BoxWithConstraints(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            contentAlignment = Alignment.Center,
        ) {
            PlayerArtwork(
                art = song?.let { queueSongCoverArt(it) },
                side = minOf(maxWidth, maxHeight, ArtworkMaxSize),
            )
        }
        SongLine(
            state = state,
            song = song,
            modifier = Modifier.padding(top = 24.dp, bottom = 12.dp),
        )
        if (!state.isRadio) PlayerProgress()
        TransportControls(state, modifier = Modifier.padding(top = 8.dp))
        VolumeBar(modifier = Modifier.padding(top = 12.dp))
    }
}

/** Square artwork that swaps with a short scale and fade; a radio shows an icon instead. */
@Composable
private fun PlayerArtwork(art: CoverArt?, side: Dp) {
    val palette = LocalPlayerPalette.current
    val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
    val shape = MaterialTheme.shapes.large
    AnimatedContent(
        targetState = art,
        transitionSpec = {
            (fadeIn(effects) + scaleIn(effects, initialScale = 0.92f))
                .togetherWith(fadeOut(effects) + scaleOut(effects, targetScale = 1.05f))
                .using(SizeTransform(clip = false))
        },
        modifier = Modifier.size(side),
        label = "playerArtwork",
    ) { current ->
        if (current == null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(shape)
                    .background(palette.container),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Rounded.Radio,
                    contentDescription = null,
                    tint = palette.muted,
                    modifier = Modifier.fillMaxSize(0.36f),
                )
            }
        } else {
            CoverImage(
                art = current,
                modifier = Modifier.fillMaxSize(),
                kind = CoverKind.Song,
                shape = shape,
            )
        }
    }
}

/** Title and artist with the like and options buttons of the current song. */
@Composable
private fun SongLine(state: PlayerState, song: QueueSong?, modifier: Modifier = Modifier) {
    val palette = LocalPlayerPalette.current
    val effects = MaterialTheme.motionScheme.defaultEffectsSpec<Float>()
    val title = state.radio?.name?.takeIf { state.isRadio } ?: song?.title.orEmpty()
    val subtitle = if (state.isRadio) t("radios.label") else song?.artist.orEmpty()

    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        AnimatedContent(
            targetState = title to subtitle,
            transitionSpec = {
                (fadeIn(effects) + slideInVertically(initialOffsetY = { it / 4 }))
                    .togetherWith(fadeOut(effects))
            },
            modifier = Modifier.weight(1f),
            label = "songLine",
        ) { (currentTitle, currentSubtitle) ->
            Column {
                Text(
                    text = currentTitle,
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    modifier = Modifier.basicMarquee(),
                )
                Text(
                    text = currentSubtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = palette.muted,
                    maxLines = 1,
                    modifier = Modifier.basicMarquee(),
                )
            }
        }
        if (song != null) {
            LikeButton(state = state, song = song)
            SongOptionsButton(song = song)
        }
    }
}

/** Heart for the current song; filled red once it is liked. */
@Composable
fun LikeButton(
    state: PlayerState,
    song: QueueSong,
    modifier: Modifier = Modifier,
    iconSize: Dp = 26.dp,
) {
    val player = LocalAppGraph.current.player
    val palette = LocalPlayerPalette.current
    val starred = state.isCurrentStarred
    IconToggleButton(
        checked = starred,
        onCheckedChange = { player.toggleCurrentLike() },
        modifier = modifier,
        colors = IconButtonDefaults.iconToggleButtonColors(
            contentColor = palette.content,
            checkedContainerColor = Color.Transparent,
            checkedContentColor = LikedColor,
        ),
    ) {
        Icon(
            imageVector = if (starred) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
            contentDescription = t(
                if (starred) "player.tooltips.dislike" else "player.tooltips.like",
                "song" to song.title,
                "artist" to song.artist,
            ),
            modifier = Modifier.size(iconSize),
        )
    }
}

/** Opens the options of the current song. */
@Composable
fun SongOptionsButton(song: QueueSong, modifier: Modifier = Modifier, iconSize: Dp = 24.dp) {
    val overlays = LocalOverlays.current
    PlayerIconButton(
        icon = Icons.Rounded.MoreVert,
        description = t("playlist.buttons.options", "name" to song.title),
        onClick = { overlays.show(Overlay.CurrentSongMenu) },
        modifier = modifier,
        iconSize = iconSize,
    )
}
