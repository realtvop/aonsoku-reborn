package github.realtvop.aonsoku.ui.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import github.realtvop.aonsoku.player.PlayerState
import github.realtvop.aonsoku.plugins.audio.QueueSong
import github.realtvop.aonsoku.ui.components.CoverImage
import github.realtvop.aonsoku.ui.components.CoverKind
import github.realtvop.aonsoku.ui.components.queueSongCoverArt

val CurrentSongRowHeight = 72.dp

/** Rows of the player's tabs start this far from the edge, and their content a little further. */
val PlayerRowInset = 8.dp
val PlayerRowContentInset = 12.dp

/**
 * The song that is playing, on top of the tabs that are not about it alone
 * (queue, lyrics); tapping it returns to the playing view.
 */
@Composable
fun CurrentSongRow(
    state: PlayerState,
    song: QueueSong,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalPlayerPalette.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = PlayerRowInset)
            .clip(MaterialTheme.shapes.medium)
            .clickable(onClick = onClick)
            .heightIn(min = CurrentSongRowHeight)
            .padding(start = PlayerRowContentInset),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverImage(
            art = queueSongCoverArt(song),
            modifier = Modifier.size(48.dp),
            kind = CoverKind.Song,
            shape = MaterialTheme.shapes.small,
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = song.title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = song.artist,
                style = MaterialTheme.typography.bodySmall,
                color = palette.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        LikeButton(state = state, song = song, iconSize = 22.dp)
        SongOptionsButton(song = song, iconSize = 22.dp)
    }
}
