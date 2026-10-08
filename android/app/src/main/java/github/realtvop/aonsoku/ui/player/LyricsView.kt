package github.realtvop.aonsoku.ui.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import github.realtvop.aonsoku.utils.LrcParser
import github.realtvop.aonsoku.viewmodel.PlaybackViewModel

@Composable
fun LyricsView(
    viewModel: PlaybackViewModel,
    modifier: Modifier = Modifier,
) {
    val lyrics by viewModel.lyrics.collectAsState()
    val playbackState by viewModel.playbackState.collectAsState()

    val rawContent = lyrics?.content
    val parsedLines = remember(rawContent) {
        LrcParser.parse(rawContent)
    }

    val isSynced = parsedLines.any { it.timeSeconds >= 0 }

    if (parsedLines.isEmpty()) {
        Box(
            modifier = modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "No lyrics available",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
        }
        return
    }

    if (!isSynced) {
        // Plain text lyrics
        LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            itemsIndexed(parsedLines) { _, line ->
                Text(
                    text = line.text,
                    style = MaterialTheme.typography.bodyLarge.copy(
                        fontSize = 18.sp,
                        lineHeight = 28.sp,
                        fontWeight = FontWeight.Medium,
                    ),
                    color = MaterialTheme.colorScheme.onSurface,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(vertical = 6.dp),
                )
            }
        }
        return
    }

    // Synced lyrics
    val currentTime = playbackState.currentTimeSeconds
    val activeIndex = remember(currentTime, parsedLines) {
        var index = -1
        for (i in parsedLines.indices) {
            if (parsedLines[i].timeSeconds <= currentTime) {
                index = i
            } else {
                break
            }
        }
        index
    }

    val listState = rememberLazyListState()

    LaunchedEffect(activeIndex) {
        if (activeIndex >= 0) {
            listState.animateScrollToItem(
                index = activeIndex,
                scrollOffset = -250, // Keep active line centered
            )
        }
    }

    LazyColumn(
        state = listState,
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 200.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        itemsIndexed(parsedLines) { index, line ->
            val isActive = index == activeIndex
            val isPassed = index < activeIndex

            Text(
                text = line.text,
                style = MaterialTheme.typography.headlineSmall.copy(
                    fontWeight = if (isActive) FontWeight.ExtraBold else FontWeight.SemiBold,
                    fontSize = if (isActive) 26.sp else 20.sp,
                    lineHeight = if (isActive) 34.sp else 28.sp,
                ),
                color = when {
                    isActive -> MaterialTheme.colorScheme.primary
                    isPassed -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f)
                    else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                },
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .clickable {
                        if (line.timeSeconds >= 0) {
                            viewModel.seek(line.timeSeconds)
                        }
                    }
                    .padding(vertical = 12.dp, horizontal = 8.dp),
            )
        }
    }
}
