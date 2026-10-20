import Foundation

/// Text from the server for display. Album notes and artist biographies
/// arrive as HTML from Last.fm; song comments are plain text that may hold
/// bare links.
enum RichText {
    /// Converts notes or a biography to styled text. Line breaks and
    /// paragraphs stay, web and mail anchors become links, and every other
    /// tag is dropped, like the web `sanitizeLinks`.
    static func html(_ html: String) -> AttributedString {
        let source = html
            .replacing("\r\n", with: "\n")
            .replacing(#/<br\s*/?>/#.ignoresCase(), with: "\n")
            .replacing(#/</p\s*>/#.ignoresCase(), with: "\n\n")
        let anchor = #/<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>(.*?)</a\s*>/#
            .ignoresCase()
            .dotMatchesNewlines()

        var result = AttributedString()
        var rest = source[...]
        while let match = rest.firstMatch(of: anchor) {
            result += linkified(plainText(String(rest[..<match.range.lowerBound])))
            let label = plainText(String(match.output.2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let href = decodeEntities(String(match.output.1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: href), isAllowed(url), !label.isEmpty {
                var link = AttributedString(label)
                link.link = url
                result += link
            } else {
                result += AttributedString(label)
            }
            rest = rest[match.range.upperBound...]
        }
        result += linkified(plainText(String(rest)))
        return trimmed(result)
    }

    /// `text` with its web addresses and email addresses as links, like the
    /// web `linkifyText`.
    static func linkified(_ text: String) -> AttributedString {
        guard let detector = linkDetector else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let url = match.url, isAllowed(url),
                  let range = Range(match.range, in: text), range.lowerBound >= cursor
            else { continue }
            result += AttributedString(text[cursor ..< range.lowerBound])
            var link = AttributedString(text[range])
            link.link = url
            result += link
            cursor = range.upperBound
        }
        result += AttributedString(text[cursor...])
        return result
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }

    /// A run of HTML without anchors as plain text: no tags, entities
    /// decoded, and spaces collapsed while line breaks stay.
    private static func plainText(_ html: String) -> String {
        decodeEntities(html.replacing(#/<[^>]+>/#, with: ""))
            .replacing(#/[ \t\f\r]+/#, with: " ")
            .replacing(#/ *\n */#, with: "\n")
            .replacing(#/\n{3,}/#, with: "\n\n")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(#/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});/#) { match in
            let entity = match.output.1
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                return scalar(UInt32(entity.dropFirst(2), radix: 16)) ?? String(match.output.0)
            }
            if entity.hasPrefix("#") {
                return scalar(UInt32(entity.dropFirst(), radix: 10)) ?? String(match.output.0)
            }
            return namedEntities[entity.lowercased()] ?? String(match.output.0)
        }
    }

    private static func scalar(_ value: UInt32?) -> String? {
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•",
    ]

    /// `text` without leading or trailing whitespace.
    private static func trimmed(_ text: AttributedString) -> AttributedString {
        let characters = text.characters
        var start = characters.startIndex
        var end = characters.endIndex
        while start < end, characters[start].isWhitespace {
            start = characters.index(after: start)
        }
        while start < end {
            let before = characters.index(before: end)
            guard characters[before].isWhitespace else { break }
            end = before
        }
        return AttributedString(text[start ..< end])
    }
}

extension AttributedString {
    /// The characters without styling, for previews.
    var plainText: String {
        String(characters)
    }
}
