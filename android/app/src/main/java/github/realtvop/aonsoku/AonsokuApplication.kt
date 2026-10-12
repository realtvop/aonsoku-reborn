package github.realtvop.aonsoku

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.request.crossfade
import github.realtvop.aonsoku.data.image.AvatarArtKeyer
import github.realtvop.aonsoku.data.image.CoverArtFetcher
import github.realtvop.aonsoku.data.image.CoverArtKeyer

class AonsokuApplication : Application(), SingletonImageLoader.Factory {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this).also { it.initialize() }
        ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : DefaultLifecycleObserver {
                override fun onStart(owner: LifecycleOwner) = graph.onForeground()

                override fun onStop(owner: LifecycleOwner) = graph.onBackground()
            },
        )
    }

    /** Artwork is served from the native image cache instead of HTTP. */
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components {
                add(CoverArtFetcher.CoverFactory(graph.artwork))
                add(CoverArtFetcher.AvatarFactory(graph.artwork))
                add(CoverArtKeyer())
                add(AvatarArtKeyer())
            }
            .crossfade(true)
            .build()
}
