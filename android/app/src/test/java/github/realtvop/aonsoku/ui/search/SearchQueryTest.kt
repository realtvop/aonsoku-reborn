package github.realtvop.aonsoku.ui.search

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchQueryTest {
    @Test
    fun latinQueriesNeedThreeCharacters() {
        assertFalse(SearchViewModel.isSearchable(""))
        assertFalse(SearchViewModel.isSearchable("ab"))
        assertTrue(SearchViewModel.isSearchable("abc"))
    }

    @Test
    fun oneWideCharacterIsEnough() {
        // CJK characters take three UTF-8 bytes each.
        assertTrue(SearchViewModel.isSearchable("歌"))
        assertFalse(SearchViewModel.isSearchable("é"))
        assertTrue(SearchViewModel.isSearchable("éa"))
    }
}
