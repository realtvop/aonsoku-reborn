import Foundation

// Lyrics value types. They mirror the web lyrics pipeline
// (`src/app/components/fullscreen/lyrics*`, `src/service/lyrics*`,
// `src/utils/lrc*`): Navidrome, LRCLIB and a custom lyrics server, synced
// lines with optional translation and romanization, and a per-song custom
// selection with a timing offset.

/// Where lyrics come from. Raw values match the web `sourcePriority` items.
public enum LyricsSource: String, Codable, Hashable, Sendable, CaseIterable {
    case navidrome
    case lrclib
    case custom
}

/// One displayed lyric line. Unsynced lyrics use `start` and `end` of 0.
public struct LyricLine: Identifiable, Hashable, Sendable {
    /// Position in the lyrics, starting at 0.
    public var id: Int
    /// Seconds from the start of the song, before the per-song offset.
    public var start: TimeInterval
    /// Seconds; the next line's start, or the song end for the last line.
    public var end: TimeInterval
    public var text: String
    public var translation: String?
    public var romanization: String?

    public init(
        id: Int,
        start: TimeInterval = 0,
        end: TimeInterval = 0,
        text: String,
        translation: String? = nil,
        romanization: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
        self.romanization = romanization
    }
}

/// Lyrics resolved for one song.
public struct SongLyrics: Hashable, Sendable {
    public var lines: [LyricLine]
    public var isSynced: Bool
    public var source: LyricsSource
    /// Display name of the lyrics author or provider, when known.
    public var credit: String?

    public init(
        lines: [LyricLine],
        isSynced: Bool,
        source: LyricsSource,
        credit: String? = nil
    ) {
        self.lines = lines
        self.isSynced = isSynced
        self.source = source
        self.credit = credit
    }

    public var hasTranslation: Bool { lines.contains { $0.translation != nil } }
    public var hasRomanization: Bool { lines.contains { $0.romanization != nil } }

    /// The active line for a playback position that already includes the
    /// per-song offset, or nil before the first line and for unsynced lyrics.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard isSynced, !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// Lyrics loading state for the current song.
public enum LyricsLoadState: Hashable, Sendable {
    case idle
    case loading
    case loaded(SongLyrics)
    /// No source had lyrics for the song.
    case unavailable
    /// The user turned lyrics off for this song.
    case disabled

    public var lyrics: SongLyrics? {
        if case let .loaded(lyrics) = self { return lyrics }
        return nil
    }
}

/// One search result from the custom lyrics server.
public struct CustomLyricsCandidate: Identifiable, Hashable, Sendable {
    /// `candidateKey`: the server id, or `"<index>:<artist>:<title>"`.
    public var id: String
    public var serverId: String?
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds, when the server reports it.
    public var duration: TimeInterval?
    public var isSynced: Bool
    /// Raw lyrics text (LRC or plain).
    public var lyrics: String
    /// Raw romanization text (LRC), when the server provides it.
    public var romaji: String?

    public init(
        id: String,
        serverId: String? = nil,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil,
        isSynced: Bool,
        lyrics: String,
        romaji: String? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isSynced = isSynced
        self.lyrics = lyrics
        self.romaji = romaji
    }
}

/// The user's per-song lyrics choice, keyed by the song key
/// (`[path, artist, title, album].joined("\u{1F}")`). Mirrors the web
/// `selectedCustomLyrics` entries; at most 50 songs are remembered.
public struct CustomLyricsSelection: Codable, Hashable, Sendable {
    /// Selected candidate key, or nil to use the automatic sources.
    public var key: String?
    public var serverId: String?
    public var title: String?
    public var artist: String?
    /// Raw lyrics of the selected candidate.
    public var lyrics: String?
    public var romaji: String?
    /// Lyrics are hidden for this song.
    public var disabled: Bool
    /// Seconds added to playback time when matching lines, -2...2 in 0.1
    /// steps.
    public var offset: Double

    public init(
        key: String? = nil,
        serverId: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        lyrics: String? = nil,
        romaji: String? = nil,
        disabled: Bool = false,
        offset: Double = 0
    ) {
        self.key = key
        self.serverId = serverId
        self.title = title
        self.artist = artist
        self.lyrics = lyrics
        self.romaji = romaji
        self.disabled = disabled
        self.offset = offset
    }

    public static let offsetRange: ClosedRange<Double> = -2...2
    public static let offsetStep: Double = 0.1
    public static let maxRemembered = 50

    /// True when the entry carries nothing worth remembering.
    public var isDefault: Bool { key == nil && !disabled && offset == 0 }
}
