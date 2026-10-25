import Foundation

// Player value types for the UI. They mirror the web player store
// (`src/types/playerContext.ts`, `src/store/player/`) on top of the native
// queue owned by `AudioService`.

/// What a context queue was started from. Encoded as `"<kind>:<id>"` in
/// queue snapshots and coordination messages.
public struct QueueSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case album
        case playlist
        case radio
        case artist
        case genre
    }

    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// Parses `"<kind>:<id>"`; nil for anything else.
    public init?(encoded: String?) {
        guard let encoded, let separator = encoded.firstIndex(of: ":") else { return nil }
        guard let kind = Kind(rawValue: String(encoded[..<separator])) else { return nil }
        let id = String(encoded[encoded.index(after: separator)...])
        guard !id.isEmpty else { return nil }
        self.init(kind: kind, id: id)
    }

    public var encoded: String { "\(kind.rawValue):\(id)" }

    public static func album(_ id: String) -> QueueSource { QueueSource(kind: .album, id: id) }
    public static func playlist(_ id: String) -> QueueSource { QueueSource(kind: .playlist, id: id) }
    public static func artist(_ id: String) -> QueueSource { QueueSource(kind: .artist, id: id) }
    public static func genre(_ id: String) -> QueueSource { QueueSource(kind: .genre, id: id) }
}

/// Which list a queue row belongs to.
public enum QueueTier: String, Hashable, Sendable {
    /// The album, playlist or other list playback was started from.
    case context
    /// Songs the user added with Play Next or Add to Queue.
    case user
}

/// One queue row. `id` stays unique when a song appears more than once.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var song: Song
    public var tier: QueueTier
    /// Position in the tier's full list, used by queue commands.
    public var index: Int

    public init(song: Song, tier: QueueTier, index: Int) {
        self.id = "\(tier.rawValue):\(index):\(song.id)"
        self.song = song
        self.tier = tier
        self.index = index
    }
}

/// The queue as shown in Now Playing.
public struct PlayerQueue: Hashable, Sendable {
    /// Context songs before the current one, oldest first.
    public var history: [QueueEntry]
    public var current: QueueEntry?
    /// Songs the user queued, played before the rest of the context.
    public var userQueue: [QueueEntry]
    /// Remaining context songs after the current one.
    public var upNext: [QueueEntry]
    public var source: QueueSource?
    public var sourceName: String?

    public init(
        history: [QueueEntry] = [],
        current: QueueEntry? = nil,
        userQueue: [QueueEntry] = [],
        upNext: [QueueEntry] = [],
        source: QueueSource? = nil,
        sourceName: String? = nil
    ) {
        self.history = history
        self.current = current
        self.userQueue = userQueue
        self.upNext = upNext
        self.source = source
        self.sourceName = sourceName
    }

    public static let empty = PlayerQueue()

    public var isEmpty: Bool { current == nil && userQueue.isEmpty && upNext.isEmpty }

    /// Songs still to play after the current one.
    public var remainingCount: Int { userQueue.count + upNext.count }
}

/// Repeat mode cycling, matching the web loop button: off, all, one.
extension AudioRepeatMode {
    public var next: AudioRepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// Sleep timer as shown in the player menu.
public enum SleepTimerState: Hashable, Sendable {
    case off
    /// Pauses when the current song ends.
    case endOfTrack
    /// Pauses at `endsAt`.
    case countdown(endsAt: Date)

    public var isActive: Bool { self != .off }

    /// Durations offered in the menu, in minutes.
    public static let presetMinutes = [5, 10, 15, 30, 45, 60]
}

/// Where playback commands go.
public enum PlaybackTarget: Hashable, Sendable {
    case local
    /// Controlling another device through coordination.
    case remote(deviceId: String, deviceName: String)

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    public var remoteDeviceId: String? {
        if case let .remote(deviceId, _) = self { return deviceId }
        return nil
    }
}

/// A play request that would discard songs the user queued. The player
/// asks before replacing the queue while playing (web
/// `shouldConfirmQueueReplacement`).
public struct QueueReplacementRequest: Identifiable, Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case songs([Song], index: Int, shuffle: Bool, source: QueueSource?, sourceName: String?)
        case song(Song, sourceName: String?)
    }

    public var id: UUID
    public var content: Content
    /// The controlled device when the request targets remote playback.
    public var targetDeviceId: String?

    public init(id: UUID = UUID(), content: Content, targetDeviceId: String? = nil) {
        self.id = id
        self.content = content
        self.targetDeviceId = targetDeviceId
    }

    /// Songs that "Play after this song" inserts: the single song, the
    /// selection from `index` on, or the whole selection shuffled.
    public func playNextSongs(
        shuffle: ([Song]) -> [Song] = { $0.shuffled() }
    ) -> [Song] {
        switch content {
        case let .song(song, _):
            return [song]
        case let .songs(songs, index, isShuffled, _, _):
            guard !songs.isEmpty else { return [] }
            if isShuffled { return shuffle(songs) }
            return Array(songs[min(max(index, 0), songs.count - 1)...])
        }
    }
}

/// The user's answer to a `QueueReplacementRequest`.
public enum QueueReplacementChoice: Hashable, Sendable {
    /// Clear the user queue and play the selection.
    case replace
    /// Keep the queue and insert the selection after the current song.
    case playNext
    case cancel
}

/// Where Add to Queue inserts songs.
public enum QueueInsertPosition: String, Hashable, Sendable {
    /// Right after the current song (Play Next).
    case next
    /// After the songs the user already queued (Add to Queue).
    case last
}

/// Playback of an internet radio station.
public struct RadioPlayback: Hashable, Sendable {
    public var stations: [RadioStation]
    public var index: Int

    public init(stations: [RadioStation], index: Int) {
        self.stations = stations
        self.index = index
    }

    public var current: RadioStation? {
        stations.indices.contains(index) ? stations[index] : nil
    }
}
