import Foundation

struct QueueSourceId: Codable, Equatable {
    let type: String
    let id: String
}

struct PlaybackPersistState: Codable {
    var contextSongs: [QueueSong]
    var currentIndex: Int
    var userQueue: [QueueSong]
    var originalContextSongs: [QueueSong]
    var originalUserSongs: [QueueSong]
    var isShuffleActive: Bool
    var shuffleHistory: [String]
    var shuffleStartHistory: [String]
    var loopState: String
    var isInUserQueue: Bool
    var playedUserQueueHistory: [QueueSong]
    var sourceId: QueueSourceId?
    var sourceName: String?
    var currentTime: Double

    init(from engine: NativeQueueEngine, currentTime: Double) {
        self.contextSongs = engine.contextSongs
        self.currentIndex = engine.currentIndex
        self.userQueue = engine.userQueue
        self.originalContextSongs = engine.originalContextSongs
        self.originalUserSongs = engine.originalUserSongs
        self.isShuffleActive = engine.isShuffleActive
        self.shuffleHistory = engine.shuffleHistory
        self.shuffleStartHistory = engine.shuffleStartHistory
        self.loopState = engine.loopState.rawValue
        self.isInUserQueue = engine.isInUserQueue
        self.playedUserQueueHistory = engine.playedUserQueueHistory
        self.sourceId = engine.sourceId
        self.sourceName = engine.sourceName
        self.currentTime = currentTime
    }
}
