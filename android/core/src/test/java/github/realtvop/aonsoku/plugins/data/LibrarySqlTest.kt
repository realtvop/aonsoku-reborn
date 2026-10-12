package github.realtvop.aonsoku.plugins.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LibrarySqlTest {
    @Test
    fun tokenizesOnWhitespaceAndDropsEmptyTerms() {
        assertEquals(listOf("pink", "floyd"), LibrarySql.tokenize("  pink   floyd "))
        assertTrue(LibrarySql.tokenize(null).isEmpty())
        assertTrue(LibrarySql.tokenize("   ").isEmpty())
    }

    @Test
    fun escapesLikeWildcardsInSearchTerms() {
        assertEquals("100\\%", LibrarySql.escapeLike("100%"))
        assertEquals("a\\_b", LibrarySql.escapeLike("a_b"))
        assertEquals("c\\\\d", LibrarySql.escapeLike("c\\d"))
    }

    @Test
    fun albumQueryBindsEveryUserValue() {
        val query = LibrarySql.albums(
            AlbumQuery(
                sort = AlbumSort.Name,
                search = "dark side'; DROP TABLE album;--",
                artistId = "ar-1",
                genre = "Rock",
                limit = 20,
                offset = 40,
            ),
        )

        assertFalse(query.sql.contains("DROP TABLE"))
        assertFalse(query.sql.contains("ar-1"))
        assertFalse(query.sql.contains("Rock"))
        assertTrue(query.sql.endsWith("ORDER BY name COLLATE NOCASE ASC LIMIT ? OFFSET ?"))
        // 5 search terms x 3 columns + artistId + genre + limit + offset
        assertEquals(5 * 3 + 2 + 2, query.argCount)
    }

    @Test
    fun albumSortsMapToStableOrderings() {
        fun order(sort: AlbumSort) = LibrarySql.albums(AlbumQuery(sort = sort)).sql
            .substringAfter("ORDER BY ")

        assertEquals("created DESC, name COLLATE NOCASE ASC", order(AlbumSort.RecentlyAdded))
        assertEquals("played DESC, name COLLATE NOCASE ASC", order(AlbumSort.RecentlyPlayed))
        assertEquals(
            "COALESCE(playCount, 0) DESC, name COLLATE NOCASE ASC",
            order(AlbumSort.MostPlayed),
        )
        assertEquals("COALESCE(year, 0) ASC, name COLLATE NOCASE ASC", order(AlbumSort.YearOldest))
        assertEquals("RANDOM()", order(AlbumSort.Random))
    }

    @Test
    fun albumSortsThatImplyAFilterAddIt() {
        assertTrue(
            LibrarySql.albums(AlbumQuery(sort = AlbumSort.Starred)).sql
                .contains("starredAt IS NOT NULL"),
        )
        assertTrue(
            LibrarySql.albums(AlbumQuery(sort = AlbumSort.RecentlyPlayed)).sql
                .contains("played IS NOT NULL"),
        )
        assertTrue(
            LibrarySql.albums(AlbumQuery(sort = AlbumSort.MostPlayed)).sql
                .contains("COALESCE(playCount, 0) > 0"),
        )
        assertFalse(LibrarySql.albums(AlbumQuery(sort = AlbumSort.Name)).sql.contains("WHERE"))
    }

    @Test
    fun countQueriesShareTheFiltersWithoutPaging() {
        val query = AlbumQuery(search = "blue", starredOnly = true, limit = 10, offset = 5)
        val count = LibrarySql.albumCount(query)

        assertTrue(count.sql.startsWith("SELECT COUNT(*) FROM album WHERE"))
        assertFalse(count.sql.contains("LIMIT"))
        assertEquals(3, count.argCount)
    }

    @Test
    fun songQueryHonorsDirectionAndScope() {
        val query = LibrarySql.songs(
            SongQuery(sort = SongSort.Title, ascending = true, artistId = "ar-9", limit = 50),
        )

        assertTrue(query.sql.contains("artistId = ?"))
        assertTrue(query.sql.contains("ORDER BY title COLLATE NOCASE ASC"))
        assertEquals(3, query.argCount)

        val albumOrder = LibrarySql.songs(SongQuery(sort = SongSort.AlbumOrder, albumId = "al-1"))
        assertTrue(
            albumOrder.sql.endsWith(
                "ORDER BY COALESCE(discNumber, 0) ASC, COALESCE(track, 0) ASC",
            ),
        )
        assertEquals(1, albumOrder.argCount)
    }

    @Test
    fun unlimitedQueriesOmitPaging() {
        val artists = LibrarySql.artists(ArtistQuery(search = "a b"))

        assertFalse(artists.sql.contains("LIMIT"))
        assertEquals(2, artists.argCount)
        assertTrue(LibrarySql.artistCount(ArtistQuery(starredOnly = true)).sql.contains("starredAt"))
    }
}
