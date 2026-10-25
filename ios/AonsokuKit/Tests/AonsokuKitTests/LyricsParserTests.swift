import XCTest

@testable import AonsokuKit

final class LyricsParserTests: XCTestCase {
    func testLRCParsesMultipleTagsOffsetMetadataAndEmptyGaps() throws {
        let lyrics = try XCTUnwrap(
            LyricsParser.lrc(
                """
                [ti:Title]
                [offset:500]
                [00:01.0][00:03.00]Hello
                [00:05.000]
                """,
                duration: 8,
                source: .navidrome,
                showTranslation: true
            ))

        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertEqual(lyrics.lines.map(\.start), [1.5, 3.5, 5.5])
        XCTAssertEqual(lyrics.lines.map(\.end), [3.5, 5.5, 8])
        XCTAssertEqual(lyrics.lines.map(\.text), ["Hello", "Hello", ""])
    }

    func testLRCConnectsInlineTranslationAndRomanization() throws {
        let lyrics = try XCTUnwrap(
            LyricsParser.lrc(
                "[00:01.00]こんにちは\n[00:01.00]你好\n[00:05.00]世界",
                duration: nil,
                romaji: "[00:01.00]konnichiwa\n[00:05.00]sekai",
                source: .custom,
                showTranslation: true
            ))

        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].translation, "你好")
        XCTAssertEqual(lyrics.lines[0].romanization, "konnichiwa")
        XCTAssertEqual(lyrics.lines[1].romanization, "sekai")
        XCTAssertEqual(lyrics.lines[1].end, 10)

        let hidden = try XCTUnwrap(
            LyricsParser.lrc(
                "[00:01.00]Hello\n[00:01.00]Hola",
                duration: nil,
                source: .custom,
                showTranslation: false
            ))
        XCTAssertNil(hidden.lines[0].translation)
    }

    func testStructuredLyricsApplyOffsetsExternalTranslationAndInlineRules() throws {
        let primary = SubsonicStructuredLyrics(
            synced: true,
            offset: 250,
            displayArtist: "Writer",
            lines: [
                .init(start: 1_000, value: "First"),
                .init(start: 3_000, value: "Second"),
            ]
        )
        let translation = SubsonicStructuredLyrics(
            synced: true,
            offset: 250,
            lines: [
                .init(start: 1_000, value: "Uno"),
                .init(start: 3_000, value: "Dos"),
            ]
        )
        let lyrics = try XCTUnwrap(
            LyricsParser.structured(
                [primary, translation],
                duration: 5,
                showTranslation: true
            ))

        XCTAssertEqual(lyrics.credit, "Writer")
        XCTAssertEqual(lyrics.lines.map(\.start), [1.25, 3.25])
        XCTAssertEqual(lyrics.lines.map(\.translation), ["Uno", "Dos"])

        let inline = SubsonicStructuredLyrics(
            synced: true,
            lines: [
                .init(start: 0, value: "standalone"),
                .init(start: 0, value: "main"),
                .init(start: 0, value: "translation"),
            ]
        )
        let inlineLyrics = try XCTUnwrap(
            LyricsParser.structured(
                [inline],
                duration: nil,
                showTranslation: true
            ))
        XCTAssertEqual(inlineLyrics.lines.map(\.text), ["standalone", "main"])
        XCTAssertNil(inlineLyrics.lines[0].translation)
        XCTAssertEqual(inlineLyrics.lines[1].translation, "translation")

        let hiddenInline = try XCTUnwrap(
            LyricsParser.structured(
                [inline],
                duration: nil,
                showTranslation: false
            ))
        XCTAssertEqual(hiddenInline.lines.map(\.text), ["standalone", "main"])
        XCTAssertNil(hiddenInline.lines[1].translation)
    }

    func testPlainLyricsIgnoreMetadataAndKeepBlankLines() throws {
        let lyrics = try XCTUnwrap(
            LyricsParser.plain(
                "[ar:Artist]\nFirst\n\nSecond",
                source: .lrclib
            ))

        XCTAssertFalse(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "", "Second"])
        XCTAssertNil(lyrics.lineIndex(at: 1))
    }
}
