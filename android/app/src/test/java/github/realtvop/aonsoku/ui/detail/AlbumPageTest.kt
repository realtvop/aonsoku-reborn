package github.realtvop.aonsoku.ui.detail

import github.realtvop.aonsoku.data.model.Album
import github.realtvop.aonsoku.data.model.FeaturedArtist
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AlbumPageTest {
    private fun album(id: String, year: Int? = null) = Album(id = id, name = id, year = year)

    @Test
    fun relatedAlbumsLeaveOutTheOpenAlbum() {
        val related = AlbumViewModel.relatedAlbums(
            listOf(album("a"), album("b"), album("c")),
            currentId = "b",
            newestFirst = false,
        )

        assertEquals(listOf("a", "c"), related.map { it.id })
    }

    @Test
    fun artistAlbumsAreNewestFirstWithUndatedOnesLast() {
        val related = AlbumViewModel.relatedAlbums(
            listOf(album("old", 1990), album("undated"), album("new", 2020), album("mid", 2005)),
            currentId = "none",
            newestFirst = true,
        )

        assertEquals(listOf("new", "mid", "old", "undated"), related.map { it.id })
    }

    @Test
    fun relatedAlbumsAreCapped() {
        val many = (1..40).map { album("album-$it", 2000 + it) }

        val related = AlbumViewModel.relatedAlbums(many, currentId = "album-1", newestFirst = false)

        assertEquals(AlbumViewModel.RELATED_ALBUMS, related.size)
        assertEquals("album-2", related.first().id)
    }

    @Test
    fun severalCreditedArtistsAreAllLinked() {
        val artists = listOf(FeaturedArtist("1", "One"), FeaturedArtist("2", "Two"))
        val album = Album(id = "a", artist = "One", artistId = "1", artists = artists)

        assertEquals(artists, headerArtists(album))
    }

    @Test
    fun aSingleArtistUsesTheAlbumArtist() {
        val album = Album(
            id = "a",
            artist = "One",
            artistId = "1",
            artists = listOf(FeaturedArtist("1", "One")),
        )

        assertEquals(listOf(FeaturedArtist("1", "One")), headerArtists(album))
    }

    @Test
    fun anArtistThatCannotBeOpenedIsNotLinked() {
        assertTrue(headerArtists(Album(id = "a", artist = "Various Artists")).isEmpty())
        assertTrue(headerArtists(Album(id = "a", artistId = "1")).isEmpty())
    }
}
