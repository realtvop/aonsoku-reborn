package github.realtvop.aonsoku.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.fromHtml
import androidx.compose.ui.text.style.TextDecoration

/** A web address found in plain text; [end] is exclusive. */
data class TextLink(val start: Int, val end: Int, val url: String)

private val LinkPattern = Regex("""(?:https?://|www\.)[^\s<>"']+""", RegexOption.IGNORE_CASE)
private const val TRAILING_PUNCTUATION = ".,;:!?"

/**
 * Finds the web addresses in [text]. Punctuation that ends the sentence, and
 * a closing bracket that was never opened inside the address, is left out.
 */
fun findLinks(text: String): List<TextLink> = LinkPattern.findAll(text).mapNotNull { match ->
    var raw = match.value
    while (raw.isNotEmpty()) {
        val last = raw.last()
        val closesNothing = when (last) {
            ')' -> raw.count { it == '(' } < raw.count { it == ')' }
            ']' -> raw.count { it == '[' } < raw.count { it == ']' }
            else -> false
        }
        if (last in TRAILING_PUNCTUATION || closesNothing) raw = raw.dropLast(1) else break
    }
    val hasHost = raw.substringAfter("://").removePrefix("www.").isNotEmpty()
    if (!hasHost) return@mapNotNull null
    val url = if (raw.startsWith("www.", ignoreCase = true)) "https://$raw" else raw
    TextLink(match.range.first, match.range.first + raw.length, url)
}.toList()

@Composable
fun rememberLinkStyles(): TextLinkStyles {
    val color = MaterialTheme.colorScheme.primary
    return remember(color) {
        TextLinkStyles(SpanStyle(color = color, textDecoration = TextDecoration.Underline))
    }
}

/** Plain text whose web addresses open in the browser. */
fun linkify(text: String, styles: TextLinkStyles): AnnotatedString = buildAnnotatedString {
    append(text)
    findLinks(text).forEach { link ->
        addLink(LinkAnnotation.Url(link.url, styles), link.start, link.end)
    }
}

/** Server-provided HTML (biographies, album notes) as styled text with working links. */
fun htmlText(html: String, styles: TextLinkStyles): AnnotatedString {
    val parsed = runCatching { AnnotatedString.fromHtml(html, linkStyles = styles) }
        .getOrElse { AnnotatedString(html) }
    val end = parsed.text.indexOfLast { !it.isWhitespace() } + 1
    val start = parsed.text.indexOfFirst { !it.isWhitespace() }.coerceAtLeast(0)
    return if (end <= start) AnnotatedString("") else parsed.subSequence(start, end)
}
