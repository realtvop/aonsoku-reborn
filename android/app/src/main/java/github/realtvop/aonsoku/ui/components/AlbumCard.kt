package github.realtvop.aonsoku.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import github.realtvop.aonsoku.plugins.data.db.entity.AlbumEntity

@Composable
fun AlbumCard(
    album: AlbumEntity,
    modifier: Modifier = Modifier,
    cardWidth: Dp? = null,
    onClick: () -> Unit,
) {
    val rootModifier = if (cardWidth != null) {
        modifier.width(cardWidth)
    } else {
        modifier.fillMaxWidth()
    }

    Column(
        modifier = rootModifier
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(4.dp),
    ) {
        AsyncCoverImage(
            coverArtId = album.coverArt ?: album.id,
            type = CoverType.Album,
            sizePx = 300,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f),
            shape = RoundedCornerShape(14.dp),
        )

        Spacer(modifier = Modifier.height(6.dp))

        Text(
            text = album.name,
            style = MaterialTheme.typography.bodyMedium.copy(
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
            ),
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )

        val meta = buildString {
            append(album.artist)
            val y = album.year
            if (y != null && y > 0) {
                append(" • ")
                append(y)
            }
        }
        Text(
            text = meta,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
