package github.realtvop.aonsoku.ui.components

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import coil.request.ImageRequest
import github.realtvop.aonsoku.plugins.AppServices
import github.realtvop.aonsoku.plugins.bridge.SubsonicAuthBuilder
import github.realtvop.aonsoku.plugins.data.image.ImageCacheUtils
import java.io.File
import java.net.URLEncoder

enum class CoverType {
    Song,
    Album,
    Artist
}

object SubsonicImageHelper {
    fun resolveCoverModel(context: Context, coverArtId: String?, size: Int = 300): Any? {
        if (coverArtId.isNullOrBlank()) return null

        val appContext = context.applicationContext
        val cacheDir = File(appContext.cacheDir, "images")
        val dir = ImageCacheUtils.cacheDirectory(cacheDir, false)
        if (dir.exists()) {
            val cid = ImageCacheUtils.cacheId(coverArtId)
            val file = ImageCacheUtils.coverImageFile(dir, cid)
            if (file != null && file.exists()) {
                return file
            }
        }

        val services = AppServices.getInstance(appContext)
        val credentials = services.authentication.getCredentials() ?: return null

        val params = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion,
        ).toMutableMap().apply {
            put("id", coverArtId)
            put("size", size.toString())
        }

        val queryString = params.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }

        return "${credentials.serverUrl.trimEnd('/')}/rest/getCoverArt?$queryString"
    }

    fun resolveAvatarModel(context: Context, username: String?, size: Int = 150): Any? {
        if (username.isNullOrBlank()) return null
        val appContext = context.applicationContext
        val services = AppServices.getInstance(appContext)
        val credentials = services.authentication.getCredentials() ?: return null

        val params = SubsonicAuthBuilder.buildQueryParams(
            username = credentials.username,
            password = credentials.password,
            authType = credentials.authType,
            protocolVersion = credentials.protocolVersion,
        ).toMutableMap().apply {
            put("username", username)
            put("size", size.toString())
        }

        val queryString = params.entries.joinToString("&") { (k, v) ->
            "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
        }

        return "${credentials.serverUrl.trimEnd('/')}/rest/getAvatar?$queryString"
    }
}

@Composable
fun AsyncCoverImage(
    coverArtId: String?,
    modifier: Modifier = Modifier,
    type: CoverType = CoverType.Album,
    sizePx: Int = 300,
    shape: Shape = RoundedCornerShape(12.dp),
    contentScale: ContentScale = ContentScale.Crop,
    contentDescription: String? = null,
) {
    val context = LocalContext.current
    val model = remember(coverArtId, sizePx) {
        SubsonicImageHelper.resolveCoverModel(context, coverArtId, sizePx)
    }

    val fallbackIcon = when (type) {
        CoverType.Artist -> Icons.Default.Person
        CoverType.Song -> Icons.Default.MusicNote
        CoverType.Album -> Icons.Default.Album
    }

    Box(
        modifier = modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        if (model != null) {
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(model)
                    .crossfade(true)
                    .build(),
                contentDescription = contentDescription,
                contentScale = contentScale,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(
                imageVector = fallbackIcon,
                contentDescription = contentDescription,
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                modifier = Modifier.size(28.dp),
            )
        }
    }
}
