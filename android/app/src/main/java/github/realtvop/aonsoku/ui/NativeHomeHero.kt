package github.realtvop.aonsoku.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

@Composable
fun NativeHomeHero(model: AonsokuViewModel, sections: List<HomeSection>) {
    val albums = sections.lastOrNull { it.sort == "random" }?.items.orEmpty()
    var index by remember { mutableIntStateOf(0) }
    LaunchedEffect(albums) { while (albums.isNotEmpty()) { delay(6000); index = (index + 1) % albums.size } }
    val album = albums.getOrNull(index % albums.size.coerceAtLeast(1))
    Box(Modifier.padding(horizontal = 20.dp).fillMaxWidth().height(280.dp).clip(RoundedCornerShape(32.dp)).background(MaterialTheme.colorScheme.primaryContainer).clickable(enabled = album != null) { album?.let(model::open) }) {
        if (album != null) Cover(model, album.cover, Modifier.fillMaxSize())
        Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.85f)))))
        Column(Modifier.align(Alignment.BottomStart).padding(24.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(L("Rediscover your library"), color = Color.White, style = MaterialTheme.typography.labelLarge)
            Text(album?.title ?: L("Your music, everywhere"), color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            if (album != null) Text(album.subtitle, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Button({ album?.let { model.playItem(it) } }, enabled = album != null) { Icon(Icons.Default.PlayArrow, null); Text(L("Play")) }
                Spacer(Modifier.weight(1f))
                IconButton({ if (albums.isNotEmpty()) index = (index - 1 + albums.size) % albums.size }) { Icon(Icons.Default.ChevronLeft, L("Previous album"), tint = Color.White) }
                Text("${if (albums.isEmpty()) 0 else index % albums.size + 1}/${albums.size}", color = Color.White)
                IconButton({ if (albums.isNotEmpty()) index = (index + 1) % albums.size }) { Icon(Icons.Default.ChevronRight, L("Next album"), tint = Color.White) }
            }
        }
    }
}
