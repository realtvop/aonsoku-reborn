package github.realtvop.aonsoku.plugins.data

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchHelperTest {
    @Test
    fun tokenizeSplitsNormalizedQuery() {
        val tokens = SearchHelper.tokenize("Hello World")
        assertTrue(tokens.contains("hello"))
        assertTrue(tokens.contains("world"))
    }

    @Test
    fun tokenizeRemovesDiacritics() {
        val tokens = SearchHelper.tokenize("Café résumé")
        assertTrue(tokens.contains("cafe"))
        assertTrue(tokens.contains("resume"))
    }

    @Test
    fun tokenizeReturnsEmptyForBlank() {
        assertTrue(SearchHelper.tokenize("  ").isEmpty())
        assertTrue(SearchHelper.tokenize("").isEmpty())
    }

    @Test
    fun buildConditionReturnsNullForEmptyQuery() {
        assertNull(SearchHelper.buildCondition("", listOf("name")))
        assertNull(SearchHelper.buildCondition("  ", listOf("name")))
    }

    @Test
    fun buildConditionGeneratesLikeClause() {
        val result = SearchHelper.buildCondition("hello", listOf("name"))
        assertNotNull(result)
        assertTrue(result!!.contains("LIKE"))
        assertTrue(result.contains("hello"))
    }

    @Test
    fun buildConditionHandlesMultipleColumns() {
        val result = SearchHelper.buildCondition("test", listOf("name", "title"))
        assertNotNull(result)
        assertTrue(result!!.contains("name"))
        assertTrue(result.contains("title"))
    }

    @Test
    fun buildConditionAndsMultipleTokens() {
        val result = SearchHelper.buildCondition("hello world", listOf("name"))
        assertNotNull(result)
        assertTrue(result!!.contains("AND"))
        assertTrue(result.contains("hello"))
        assertTrue(result.contains("world"))
    }
}
