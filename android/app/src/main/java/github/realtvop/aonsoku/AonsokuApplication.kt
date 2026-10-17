package github.realtvop.aonsoku

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import github.realtvop.aonsoku.data.image.artworkImageLoader

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

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        artworkImageLoader(context, graph.artwork).build()
}
