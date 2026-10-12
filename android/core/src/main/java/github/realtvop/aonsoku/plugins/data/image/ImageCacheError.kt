package github.realtvop.aonsoku.plugins.data.image
sealed class ImageCacheError(message: String) : Exception(message) {
    data object DirectoryNotFound : ImageCacheError("Directory not found")
    data object NoCredentials : ImageCacheError("No credentials")
    data class DownloadFailed(val error: Throwable) : ImageCacheError("Download: ${error.message}")
}