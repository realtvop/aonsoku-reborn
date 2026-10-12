package github.realtvop.aonsoku.data.image

import coil3.ImageLoader
import coil3.decode.DataSource
import coil3.decode.ImageSource
import coil3.fetch.FetchResult
import coil3.fetch.Fetcher
import coil3.fetch.SourceFetchResult
import coil3.key.Keyer
import coil3.request.Options
import okio.FileSystem
import okio.Path.Companion.toOkioPath

/**
 * Image model for Subsonic artwork. [ids] are cover-art ids in order of
 * preference (for example a song cover followed by its album cover).
 */
data class CoverArt(val ids: List<String>) {
    constructor(id: String?) : this(listOfNotNull(id?.takeIf { it.isNotEmpty() }))

    val isEmpty: Boolean get() = ids.isEmpty()
}

/** Image model for a user's avatar. */
data class AvatarArt(val username: String)

class CoverArtFetcher(
    private val resolve: suspend () -> java.io.File?,
) : Fetcher {
    override suspend fun fetch(): FetchResult {
        val file = resolve() ?: throw IllegalStateException("Artwork is not available")
        return SourceFetchResult(
            source = ImageSource(file = file.toOkioPath(), fileSystem = FileSystem.SYSTEM),
            mimeType = null,
            dataSource = DataSource.DISK,
        )
    }

    class CoverFactory(private val store: ArtworkStore) : Fetcher.Factory<CoverArt> {
        override fun create(data: CoverArt, options: Options, imageLoader: ImageLoader): Fetcher? =
            if (data.isEmpty) null else CoverArtFetcher { store.cover(data.ids) }
    }

    class AvatarFactory(private val store: ArtworkStore) : Fetcher.Factory<AvatarArt> {
        override fun create(data: AvatarArt, options: Options, imageLoader: ImageLoader): Fetcher =
            CoverArtFetcher { store.avatar(data.username) }
    }
}

class CoverArtKeyer : Keyer<CoverArt> {
    override fun key(data: CoverArt, options: Options): String? =
        data.ids.firstOrNull()?.let { "cover:$it" }
}

class AvatarArtKeyer : Keyer<AvatarArt> {
    override fun key(data: AvatarArt, options: Options): String = "avatar:${data.username}"
}
