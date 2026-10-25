import Foundation

enum LyricsParser {
    private struct TimedLine {
        var milliseconds: Int
        var text: String
        var order: Int
    }

    private static let timestamp = try! NSRegularExpression(
        pattern: #"\[(\d+):(\d+)[\.:](\d+)\]"#
    )
    private static let offset = try! NSRegularExpression(
        pattern: #"^\[offset:([+-]?\d+)\]$"#,
        options: [.caseInsensitive]
    )
    private static let metadata = try! NSRegularExpression(
        pattern: #"^\[(ti|ar|al|by|offset|re|ve|length):"#,
        options: [.caseInsensitive]
    )

    static func isSynced(_ content: String) -> Bool {
        normalized(content).split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(20)
            .contains { line in
                let text = String(line)
                return timestamp.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                )?.range.location == 0
            }
    }

    static func lrc(
        _ content: String,
        duration: TimeInterval?,
        romaji: String? = nil,
        source: LyricsSource,
        credit: String? = nil,
        showTranslation: Bool
    ) -> SongLyrics? {
        var lines = timedLines(content)
        guard !lines.isEmpty else { return nil }
        lines.sort {
            if $0.milliseconds == $1.milliseconds { return $0.order < $1.order }
            return $0.milliseconds < $1.milliseconds
        }

        var main: [TimedLine] = []
        var translations: [Int: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if index + 1 < lines.count,
                lines[index + 1].milliseconds == line.milliseconds
            {
                main.append(line)
                translations[main.count - 1] = lines[index + 1].text
                index += 2
            } else {
                main.append(line)
                index += 1
            }
        }

        let romanization =
            romaji.map(timedLines).map { lines in
                Dictionary(
                    lines.filter { !$0.text.isEmpty }.map { ($0.milliseconds, $0.text) },
                    uniquingKeysWith: { _, newest in newest }
                )
            } ?? [:]
        let resolved = main.enumerated().map { index, line in
            LyricLine(
                id: index,
                start: Double(line.milliseconds) / 1_000,
                end: endTime(for: index, in: main, duration: duration),
                text: line.text,
                translation: showTranslation ? translations[index] : nil,
                romanization: romanization[line.milliseconds]
            )
        }
        return SongLyrics(
            lines: resolved,
            isSynced: true,
            source: source,
            credit: credit
        )
    }

    static func plain(
        _ content: String,
        source: LyricsSource,
        credit: String? = nil
    ) -> SongLyrics? {
        let values = normalized(content)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !matches(metadata, in: $0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.contains(where: { !$0.isEmpty }) else { return nil }
        return SongLyrics(
            lines: values.enumerated().map { LyricLine(id: $0.offset, text: $0.element) },
            isSynced: false,
            source: source,
            credit: credit
        )
    }

    static func structured(
        _ tracks: [SubsonicStructuredLyrics],
        duration: TimeInterval?,
        source: LyricsSource = .navidrome,
        showTranslation: Bool
    ) -> SongLyrics? {
        guard let primary = tracks.first, !primary.lines.isEmpty else { return nil }
        if !primary.synced {
            let translated = showTranslation && tracks.count > 1 ? tracks[1].lines : []
            return SongLyrics(
                lines: primary.lines.enumerated().map { index, line in
                    LyricLine(
                        id: index,
                        text: line.value,
                        translation: translated.indices.contains(index)
                            ? translated[index].value
                            : nil
                    )
                },
                isSynced: false,
                source: source,
                credit: primary.displayArtist
            )
        }

        var sourceLines = primary.lines.map {
            TimedLine(
                milliseconds: max(($0.start ?? 0) + primary.offset, 0),
                text: $0.value,
                order: 0
            )
        }
        for index in sourceLines.indices { sourceLines[index].order = index }

        var inlineTranslations: [Int: String] = [:]
        var externalTranslations: [Int: String] = [:]
        if tracks.count > 1 {
            if showTranslation {
                let translation = tracks[1]
                for line in translation.lines where line.start != nil && !line.value.isEmpty {
                    externalTranslations[max((line.start ?? 0) + translation.offset, 0)] =
                        line.value
                }
            }
        } else {
            var main: [TimedLine] = []
            var index = 0
            while index < sourceLines.count {
                let start = sourceLines[index].milliseconds
                var end = index
                while end + 1 < sourceLines.count,
                    sourceLines[end + 1].milliseconds == start
                {
                    end += 1
                }
                if end > index {
                    if end - index > 1 {
                        main.append(contentsOf: sourceLines[index..<(end - 1)])
                    }
                    main.append(sourceLines[end - 1])
                    if showTranslation {
                        inlineTranslations[main.count - 1] = sourceLines[end].text
                    }
                } else {
                    main.append(sourceLines[index])
                }
                index = end + 1
            }
            sourceLines = main
        }

        let lines = sourceLines.enumerated().map { index, line in
            LyricLine(
                id: index,
                start: Double(line.milliseconds) / 1_000,
                end: endTime(for: index, in: sourceLines, duration: duration),
                text: line.text,
                translation: inlineTranslations[index]
                    ?? externalTranslations[line.milliseconds]
            )
        }
        return SongLyrics(
            lines: lines,
            isSynced: true,
            source: source,
            credit: primary.displayArtist
        )
    }

    private static func timedLines(_ content: String) -> [TimedLine] {
        let content = normalized(content)
        var globalOffset = 0
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            if let match = offset.firstMatch(in: line, range: range),
                let valueRange = Range(match.range(at: 1), in: line),
                let value = Int(line[valueRange])
            {
                globalOffset = value
            }
        }

        var result: [TimedLine] = []
        var order = 0
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var location = 0
            var starts: [Int] = []
            let fullRange = NSRange(line.startIndex..., in: line)
            while location < fullRange.length,
                let match = timestamp.firstMatch(
                    in: line,
                    range: NSRange(location: location, length: fullRange.length - location)
                ),
                match.range.location == location
            {
                starts.append(timestampMilliseconds(match, in: line) + globalOffset)
                location = match.range.location + match.range.length
            }
            guard !starts.isEmpty else { continue }
            let contentStart = String.Index(utf16Offset: location, in: line)
            let text = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
            for start in starts {
                result.append(
                    TimedLine(milliseconds: max(start, 0), text: text, order: order)
                )
                order += 1
            }
        }
        return result
    }

    private static func timestampMilliseconds(
        _ match: NSTextCheckingResult,
        in line: String
    ) -> Int {
        func value(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: line) else { return "0" }
            return String(line[range])
        }
        let minutes = Int(value(1)) ?? 0
        let seconds = Int(value(2)) ?? 0
        let fraction = value(3)
        var milliseconds = Int(fraction) ?? 0
        if fraction.count == 1 { milliseconds *= 100 }
        if fraction.count == 2 { milliseconds *= 10 }
        return minutes * 60_000 + seconds * 1_000 + milliseconds
    }

    private static func endTime(
        for index: Int,
        in lines: [TimedLine],
        duration: TimeInterval?
    ) -> TimeInterval {
        if lines.indices.contains(index + 1) {
            return Double(lines[index + 1].milliseconds) / 1_000
        }
        let start = Double(lines[index].milliseconds) / 1_000
        if let duration, duration > start { return duration }
        return start + 5
    }

    private static func normalized(_ content: String) -> String {
        content.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ expression: NSRegularExpression, in value: String) -> Bool {
        expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }
}
