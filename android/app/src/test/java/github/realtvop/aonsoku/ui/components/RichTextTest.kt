package github.realtvop.aonsoku.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RichTextTest {
    @Test
    fun findsAddressesWithTheirPositions() {
        val text = "Bought at https://example.com/album and http://shop.test/x?id=1 today"

        val links = findLinks(text)

        assertEquals(
            listOf("https://example.com/album", "http://shop.test/x?id=1"),
            links.map { it.url },
        )
        assertEquals("https://example.com/album", text.substring(links[0].start, links[0].end))
        assertEquals("http://shop.test/x?id=1", text.substring(links[1].start, links[1].end))
    }

    @Test
    fun leavesSentencePunctuationOutOfTheAddress() {
        val text = "See https://example.com/a, or (https://example.com/b)."

        val links = findLinks(text)

        assertEquals(listOf("https://example.com/a", "https://example.com/b"), links.map { it.url })
    }

    @Test
    fun keepsBracketsThatBelongToTheAddress() {
        val links = findLinks("https://en.wikipedia.org/wiki/Nirvana_(band) is the page")

        assertEquals("https://en.wikipedia.org/wiki/Nirvana_(band)", links.single().url)
    }

    @Test
    fun completesAddressesThatStartWithWww() {
        val text = "Visit www.example.com for more"

        val link = findLinks(text).single()

        assertEquals("https://www.example.com", link.url)
        assertEquals("www.example.com", text.substring(link.start, link.end))
    }

    @Test
    fun ignoresTextWithoutAddresses() {
        assertTrue(findLinks("Recorded in 1994. No links here: http:// or www.").isEmpty())
    }
}
