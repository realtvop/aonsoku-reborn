package github.realtvop.aonsoku.smoke

import android.app.Application
import github.realtvop.aonsoku.data.HomeCache
import github.realtvop.aonsoku.data.HomeSnapshot
import github.realtvop.aonsoku.data.model.Album
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class HomeCacheTest {
    @get:Rule
    val world = SmokeWorld()

    @Test
    fun reopeningPreservesSelectionOrderAndRandomAgeAcrossDynamicUpdates() {
        val cache = world.graph.homeCache
        val snapshot = HomeSnapshot(
            accountKey = "server:user",
            carousel = listOf(Album(id = "second"), Album(id = "first")),
            sections = mapOf("Explore" to listOf(Album(id = "explore"))),
            carouselUpdatedAt = 1_800_000_000_000L,
            exploreUpdatedAt = 1_800_000_000_000L,
        )
        world.await { cache.write(snapshot) }
        // Updating a dynamic section must not slide the recommendation expiry.
        val read = world.await { cache.read("server:user") }!!
        world.await { cache.write(read.copy(sections = read.sections + ("RecentlyAdded" to emptyList()))) }
        val reopened = HomeCache(world.graph.services.preferences)
        val restored = world.await { reopened.read("server:user") }!!
        assertEquals(listOf("second", "first"), restored.carousel!!.map { it.id })
        assertEquals(snapshot.carouselUpdatedAt, restored.carouselUpdatedAt)
        assertEquals(snapshot.exploreUpdatedAt, restored.exploreUpdatedAt)
        assertNull(world.await { reopened.read("server:other-user") })
    }

    @Test
    fun legacyUntimedSnapshotsRemainReadableWithoutLosingTheirSelection() {
        world.await {
            world.graph.services.preferences.setPreference(
                "home.snapshot.v1",
                """{"accountKey":"server:user","carousel":[{"id":"kept"}],"sections":{}}""",
            )
        }
        val restored = world.await { world.graph.homeCache.read("server:user") }!!
        assertEquals(listOf("kept"), restored.carousel!!.map { it.id })
        assertNull(restored.carouselUpdatedAt)
        assertNull(restored.exploreUpdatedAt)
    }
}
