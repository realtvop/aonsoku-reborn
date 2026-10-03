import Foundation

public enum AudioSource: Equatable, Sendable {
    case stream(url: String, songId: String?)
    case blob(url: String, songId: String?)
    case nativeFile(uri: String, songId: String?)
    case radio(url: String, radioId: String?)
}

public struct AudioMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?
    public var artworkUrl: String?
    public var coverArtId: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: Double? = nil,
        artworkUrl: String? = nil,
        coverArtId: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkUrl = artworkUrl
        self.coverArtId = coverArtId
    }
}

public struct AudioLoadRequest: Equatable, Sendable {
    public let source: AudioSource
    public let metadata: AudioMetadata
    public let autoplay: Bool
    public let startTime: Double
    public let requestId: String?

    public init(
        source: AudioSource,
        metadata: AudioMetadata = AudioMetadata(),
        autoplay: Bool = false,
        startTime: Double = 0,
        requestId: String? = nil
    ) {
        self.source = source
        self.metadata = metadata
        self.autoplay = autoplay
        self.startTime = max(0, startTime)
        self.requestId = requestId
    }
}

public enum AudioRepeatMode: String, Codable, Sendable {
    case off
    case one
    case all
}

public struct AudioQueueSource: Codable, Equatable, Sendable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }
}

public struct AudioQueueSnapshot: Equatable, Sendable {
    public let contextSongs: [QueueSong]
    public let currentIndex: Int
    public let sourceId: AudioQueueSource?
    public let sourceName: String?
    public let userQueue: [QueueSong]
    public let originalContextSongs: [QueueSong]
    public let originalUserSongs: [QueueSong]
    public let shuffleHistory: [String]
    public let shuffleStartHistory: [String]
    public let playedUserQueueHistory: [QueueSong]
    public let isInUserQueue: Bool
    public let isShuffleActive: Bool
    public let loopState: AudioRepeatMode
    public let isPlaying: Bool
    public let currentTime: Double
    public let duration: Double
    public let currentSongId: String?
    public let isRestored: Bool
}

public struct AudioPlaybackSnapshot: Equatable, Sendable {
    public enum State: String, Sendable {
        case idle
        case loading
        case playing
        case paused
        case stopped
        case ended
        case failed
    }

    public let state: State
    public let currentTime: Double
    public let duration: Double
    public let bufferedTime: Double
    public let metadata: AudioMetadata
    public let queue: AudioQueueSnapshot?
}

public struct AudioRemotePlaybackProjection: Equatable, Sendable {
    public let metadata: AudioMetadata
    public let isPlaying: Bool
    public let position: Double
    public let duration: Double
    public let isShuffleActive: Bool
    public let repeatMode: AudioRepeatMode
    public let volume: Double?
    public let targetDeviceId: String?
    public let expectedGeneration: Int?
}

public struct AudioHandoffSnapshot: Equatable, Sendable {
    public let songId: String
    public let progressSeconds: Double
    public let contextQueue: [String]
    public let contextIndex: Int
    public let userQueue: [String]
    public let inUserQueue: Bool
    public let restorePrevious: [String]
    public let shuffle: Bool
    public let repeatMode: AudioRepeatMode
    public let sourceId: AudioQueueSource?
    public let sourceName: String?
    public let volume: Double?
}

public enum AudioCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case stop
    case previous
    case next
    case seek(Double)
    case setShuffle(Bool)
    case setRepeat(AudioRepeatMode)
    case setVolume(Double)
    case playSong(String)
    case playAlbum(id: String, index: Int, shuffle: Bool)
    case playPlaylist(id: String, index: Int, shuffle: Bool)
    case playAtIndex(songIds: [String], index: Int)
    case addToQueue(songIds: [String], position: String)
    case removeFromQueue(songIds: [String])
    case reorderQueue(from: Int, to: Int)
    case clearQueue
    case toggleLike
}

public struct CachedAudioFile: Equatable, Sendable {
    public let songId: String
    public let uri: String
    public let contentType: String?
    public let sizeBytes: Int64?
    public let lastModifiedAt: Double?
}

struct NativeCachedAudioFileMetadata: Codable {
    var songId: String
    var fileName: String
    var contentType: String?
    var lastModifiedAt: Double
}

public enum AudioServiceEvent: Sendable {
    case playbackStateChanged(AudioPlaybackSnapshot.State, requestId: String?)
    case progress(currentTime: Double, duration: Double, bufferedTime: Double, requestId: String?)
    case durationChanged(Double, requestId: String?)
    case bufferingChanged(Bool, requestId: String?)
    case ended(reason: String, requestId: String?)
    case error(code: String, message: String, requestId: String?)
    case remoteCommand(command: String, position: Double?)
    case interruptionChanged(type: String, shouldResume: Bool?)
    case routeChanged(reason: String)
    case queueStateChanged(index: Int, songId: String, reason: String, isInUserQueue: Bool)
    case queueContentsChanged(reason: String)
    case downloadProgress(songId: String, loaded: Int64, total: Int64)
    case downloadCompleted(songId: String, file: CachedAudioFile)
    case downloadFailed(songId: String, message: String)
    case streamCacheCompleted(songId: String, file: CachedAudioFile)
    case bufferComplete(songId: String, requestId: String?)
    case systemVolumeChanged(Float)
    case recoveryAttempt(level: Int, attempt: Int, maxAttempts: Int)
    case sleepTimerFired(reason: String)
}

public struct AudioServiceError: LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String

    public var errorDescription: String? { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
