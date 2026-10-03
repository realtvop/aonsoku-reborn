import Foundation

public struct QueueSong: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let artistId: String?
    public let album: String
    public let albumId: String?
    public let duration: Double
    public let coverArtId: String?
    public let streamUrl: String
    public let cachedFileUri: String?

    public init(
        id: String,
        title: String,
        artist: String,
        artistId: String? = nil,
        album: String,
        albumId: String? = nil,
        duration: Double,
        coverArtId: String? = nil,
        streamUrl: String,
        cachedFileUri: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.albumId = albumId
        self.duration = duration
        self.coverArtId = coverArtId
        self.streamUrl = streamUrl
        self.cachedFileUri = cachedFileUri
    }

    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? ""
        self.title = dict["title"] as? String ?? ""
        self.artist = dict["artist"] as? String ?? ""
        self.artistId = dict["artistId"] as? String
        self.album = dict["album"] as? String ?? ""
        self.albumId = dict["albumId"] as? String
        self.duration = dict["duration"] as? Double ?? 0
        self.coverArtId = dict["coverArtId"] as? String
        self.streamUrl = dict["streamUrl"] as? String ?? ""
        self.cachedFileUri = dict["cachedFileUri"] as? String
    }

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "artist": artist,
            "album": album,
            "duration": duration,
            "streamUrl": streamUrl,
        ]
        if let artistId = artistId { dict["artistId"] = artistId }
        if let albumId = albumId { dict["albumId"] = albumId }
        if let coverArtId = coverArtId { dict["coverArtId"] = coverArtId }
        if let cachedFileUri = cachedFileUri { dict["cachedFileUri"] = cachedFileUri }
        return dict
    }
}

enum LoopState: String {
    case off
    case one
    case all
}

enum QueueAdvanceReason: String {
    case next
    case previous
    case ended
    case skip
}

protocol NativeQueueEngineDelegate: AnyObject {
    func queueEngine(_ engine: NativeQueueEngine, loadSong song: QueueSong, autoplay: Bool, startTime: Double?)
    func queueEngine(_ engine: NativeQueueEngine, didAdvanceTo index: Int, songId: String, reason: QueueAdvanceReason)
    func queueEngine(_ engine: NativeQueueEngine, didChangeContents reason: String)
    func queueEngineDidExhaustQueue(_ engine: NativeQueueEngine)
    func queueEngine(_ engine: NativeQueueEngine, seekToStart song: QueueSong)
}

class NativeQueueEngine {
    weak var delegate: NativeQueueEngineDelegate?

    private(set) var contextSongs: [QueueSong] = []
    private(set) var originalContextSongs: [QueueSong] = []
    private(set) var currentIndex: Int = 0

    private(set) var userQueue: [QueueSong] = []
    private(set) var originalUserSongs: [QueueSong] = []
    private(set) var isInUserQueue: Bool = false
    private(set) var playedUserQueueHistory: [QueueSong] = []

    private(set) var loopState: LoopState = .off
    private(set) var isShuffleActive: Bool = false
    private(set) var shuffleHistory: [String] = []
    private(set) var shuffleStartHistory: [String] = []
    private(set) var sourceId: QueueSourceId?
    private(set) var sourceName: String?

    private let shuffleEngine = NativeShuffleEngine()
    private let prevSeekThreshold: Double = 3.0

    private var maxShuffleHistory: Int {
        max(20, min(contextSongs.count / 2, 200))
    }

    private var maxShuffleStartHistory: Int {
        max(10, min(contextSongs.count / 4, 50))
    }

    var currentSong: QueueSong? {
        if isInUserQueue, !userQueue.isEmpty {
            return userQueue.first
        }
        guard currentIndex >= 0, currentIndex < contextSongs.count else {
            return nil
        }
        return contextSongs[currentIndex]
    }

    var hasNext: Bool {
        if isInUserQueue && userQueue.count > 1 { return true }
        if !isInUserQueue && !userQueue.isEmpty { return true }
        if currentIndex < contextSongs.count - 1 { return true }
        if loopState == .all && !contextSongs.isEmpty { return true }
        return false
    }

    var hasPrev: Bool {
        if !playedUserQueueHistory.isEmpty { return true }
        if isInUserQueue { return true }
        if currentIndex > 0 { return true }
        return false
    }

    // MARK: - Queue Setup

    func setContextQueue(
        songs: [QueueSong],
        currentIndex: Int,
        autoplay: Bool,
        startTime: Double?,
        sourceId: QueueSourceId? = nil,
        sourceName: String? = nil
    ) {
        self.contextSongs = songs
        self.originalContextSongs = []
        self.currentIndex = max(0, min(currentIndex, songs.count - 1))
        self.userQueue = []
        self.originalUserSongs = []
        self.isInUserQueue = false
        self.playedUserQueueHistory = []
        self.isShuffleActive = false
        self.shuffleHistory = []
        self.sourceId = sourceId
        self.sourceName = sourceName

        if let song = self.currentSong {
            delegate?.queueEngine(self, loadSong: song, autoplay: autoplay, startTime: startTime)
        }
    }

    func updateContextQueue(songs: [QueueSong], currentIndex: Int) {
        let previousSongId = self.currentSong?.id
        self.contextSongs = songs
        self.currentIndex = max(0, min(currentIndex, songs.count - 1))
        self.originalContextSongs = originalContextSongs.filter { orig in
            songs.contains { $0.id == orig.id }
        }

        let newSongId = self.currentSong?.id
        if previousSongId != newSongId {
            if let song = self.currentSong {
                delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: nil)
                delegate?.queueEngine(self, didAdvanceTo: self.currentIndex, songId: song.id, reason: .skip)
            }
        } else {
            delegate?.queueEngine(self, didChangeContents: "queue-edit")
        }
    }

    func reorderContextQueue(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < contextSongs.count,
              toIndex >= 0, toIndex < contextSongs.count else { return }

        let song = contextSongs.remove(at: fromIndex)
        contextSongs.insert(song, at: toIndex)
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func addToUserQueue(songs: [QueueSong], position: String) {
        if position == "next" {
            let insertIndex = isInUserQueue ? 1 : 0
            userQueue.insert(contentsOf: songs, at: min(insertIndex, userQueue.count))
        } else {
            userQueue.append(contentsOf: songs)
        }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func removeFromUserQueue(indices: [Int]) {
        let sorted = indices.sorted(by: >)
        for idx in sorted where idx >= 0 && idx < userQueue.count {
            userQueue.remove(at: idx)
        }
        if userQueue.isEmpty && isInUserQueue {
            isInUserQueue = false
        }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func clearUserQueue() {
        userQueue = []
        originalUserSongs = []
        playedUserQueueHistory = []
        if isInUserQueue {
            isInUserQueue = false
        }
        delegate?.queueEngine(self, didChangeContents: "queue-edit")
    }

    func playAtIndex(_ index: Int, startTime: Double?) {
        guard index >= 0, index < contextSongs.count else { return }
        isInUserQueue = false
        currentIndex = index
        if let song = currentSong {
            delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: startTime)
            delegate?.queueEngine(self, didAdvanceTo: currentIndex, songId: song.id, reason: .skip)
        }
    }

    // MARK: - Playback Control

    func handleEnded() {
        if loopState == .one {
            let userQueueRemaining = isInUserQueue
                ? userQueue.count - 1
                : userQueue.count
            if userQueueRemaining > 0 {
                advanceToNext(reason: .ended)
                return
            }
            if let song = currentSong {
                delegate?.queueEngine(self, seekToStart: song)
            }
            return
        }
        advanceToNext(reason: .ended)
    }

    func skipToNext() {
        advanceToNext(reason: .next)
    }

    func skipToPrevious(currentTime: Double) {
        if currentTime > prevSeekThreshold {
            if let song = currentSong {
                delegate?.queueEngine(self, seekToStart: song)
            }
            return
        }
        advanceToPrevious()
    }

    // MARK: - Advance Logic

    private func advanceToNext(reason: QueueAdvanceReason) {
        if isInUserQueue {
            let consumed = userQueue.removeFirst()
            playedUserQueueHistory.append(consumed)
            pushShuffleHistory(consumed.id)

            if !userQueue.isEmpty {
                notifyAdvance(reason: reason)
                return
            }

            isInUserQueue = false
            if currentIndex < contextSongs.count - 1 {
                currentIndex += 1
            } else if loopState == .all {
                wrapToStart()
            }
            notifyAdvance(reason: reason)
            return
        }

        if !userQueue.isEmpty {
            if let song = currentSong {
                pushShuffleHistory(song.id)
            }
            isInUserQueue = true
            notifyAdvance(reason: reason)
            return
        }

        if let song = currentSong {
            pushShuffleHistory(song.id)
        }

        if currentIndex < contextSongs.count - 1 {
            currentIndex += 1
            notifyAdvance(reason: reason)
            return
        }

        if loopState == .all {
            wrapToStart()
            notifyAdvance(reason: reason)
            return
        }

        delegate?.queueEngineDidExhaustQueue(self)
    }

    private func advanceToPrevious() {
        if !playedUserQueueHistory.isEmpty {
            let restored = playedUserQueueHistory.removeLast()
            userQueue.insert(restored, at: 0)
            let wasInUserQueue = isInUserQueue
            isInUserQueue = true

            if !wasInUserQueue && currentIndex > 0 {
                currentIndex -= 1
            }

            notifyAdvance(reason: .previous)
            return
        }

        if isInUserQueue {
            isInUserQueue = false
            notifyAdvance(reason: .previous)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
            notifyAdvance(reason: .previous)
        }
    }

    private func wrapToStart() {
        let lastPlayedId = contextSongs[currentIndex].id
        currentIndex = 0
        reshuffleForWrap(lastPlayedSongId: lastPlayedId)
    }

    private func notifyAdvance(reason: QueueAdvanceReason) {
        guard let song = currentSong else { return }
        delegate?.queueEngine(self, loadSong: song, autoplay: true, startTime: nil)
        delegate?.queueEngine(self, didAdvanceTo: currentIndex, songId: song.id, reason: reason)
    }

    // MARK: - Shuffle

    func setShuffleActive(_ active: Bool) {
        if active {
            applyShuffle()
        } else {
            applyUnshuffle()
        }
    }

    func markAsShuffled(originalSongs: [QueueSong]) {
        isShuffleActive = true
        originalContextSongs = originalSongs
    }

    func setLoopState(_ state: LoopState) {
        self.loopState = state
    }

    private func applyShuffle() {
        guard contextSongs.count > 1 else { return }

        originalContextSongs = contextSongs

        if let song = currentSong {
            shuffleStartHistory = shuffleEngine.pushToHistory(
                shuffleStartHistory, id: song.id, maxLen: maxShuffleStartHistory
            )
        }

        let upcoming = Array(contextSongs.suffix(from: currentIndex + 1))
        if !upcoming.isEmpty {
            let shuffled = shuffleEngine.shuffleWithGapAvoidance(upcoming, history: shuffleHistory)
            contextSongs = Array(contextSongs.prefix(currentIndex + 1)) + shuffled
        }

        if !userQueue.isEmpty {
            originalUserSongs = userQueue
            userQueue = shuffleEngine.shuffleWithGapAvoidance(userQueue, history: shuffleHistory)
        }

        isShuffleActive = true
        delegate?.queueEngine(self, didChangeContents: "shuffle")
    }

    private func applyUnshuffle() {
        guard !originalContextSongs.isEmpty else {
            isShuffleActive = false
            return
        }

        let currentSongId = currentSong?.id
        if let id = currentSongId,
           let newIdx = originalContextSongs.firstIndex(where: { $0.id == id }) {
            contextSongs = originalContextSongs
            currentIndex = newIdx
        } else {
            contextSongs = originalContextSongs
            currentIndex = min(currentIndex, contextSongs.count - 1)
        }

        if !originalUserSongs.isEmpty {
            userQueue = originalUserSongs
            originalUserSongs = []
        }

        originalContextSongs = []
        playedUserQueueHistory = []
        isShuffleActive = false
        shuffleHistory = []
        delegate?.queueEngine(self, didChangeContents: "unshuffle")
    }

    private func reshuffleForWrap(lastPlayedSongId: String?) {
        guard isShuffleActive, contextSongs.count > 1 else { return }

        let upcoming = Array(contextSongs.suffix(from: 1))
        var reshuffled = shuffleEngine.shuffleWithGapAvoidance(upcoming, history: shuffleHistory)

        if let lastId = lastPlayedSongId,
           let idx = reshuffled.firstIndex(where: { $0.id == lastId }) {
            let song = reshuffled.remove(at: idx)
            reshuffled.append(song)
        }

        contextSongs = [contextSongs[0]] + reshuffled
    }

    private func pushShuffleHistory(_ id: String) {
        shuffleHistory = shuffleEngine.pushToHistory(shuffleHistory, id: id, maxLen: maxShuffleHistory)
    }

    // MARK: - State Restoration

    private(set) var isRestored: Bool = false

    func restoreState(from persisted: PlaybackPersistState) {
        contextSongs = persisted.contextSongs
        currentIndex = persisted.currentIndex
        userQueue = persisted.userQueue
        originalContextSongs = persisted.originalContextSongs
        originalUserSongs = persisted.originalUserSongs
        isShuffleActive = persisted.isShuffleActive
        shuffleHistory = persisted.shuffleHistory
        shuffleStartHistory = persisted.shuffleStartHistory
        loopState = LoopState(rawValue: persisted.loopState) ?? .off
        isInUserQueue = persisted.isInUserQueue
        playedUserQueueHistory = persisted.playedUserQueueHistory
        sourceId = persisted.sourceId
        sourceName = persisted.sourceName
        isRestored = true
    }

    func clearRestoredFlag() {
        isRestored = false
    }

    // MARK: - State Export

    func getFullState(currentTime: Double, duration: Double, isPlaying: Bool) -> [String: Any] {
        let sourceIdValue: Any = sourceId.map { ["type": $0.type, "id": $0.id] } ?? NSNull()
        let sourceNameValue: Any = sourceName ?? NSNull()

        return [
            "contextQueue": [
                "songs": contextSongs.map { $0.toDict() },
                "currentIndex": currentIndex,
                "sourceId": sourceIdValue,
                "sourceName": sourceNameValue,
            ],
            "userQueue": userQueue.map { $0.toDict() },
            "originalContextSongs": originalContextSongs.map { $0.toDict() },
            "originalUserSongs": originalUserSongs.map { $0.toDict() },
            "isInUserQueue": isInUserQueue,
            "isShuffleActive": isShuffleActive,
            "shuffleHistory": shuffleHistory,
            "shuffleStartHistory": shuffleStartHistory,
            "playedUserQueueHistory": playedUserQueueHistory.map { $0.toDict() },
            "loopState": loopState.rawValue,
            "isPlaying": isPlaying,
            "currentTime": currentTime,
            "duration": duration,
            "currentSongId": currentSong?.id ?? NSNull(),
            "isRestored": isRestored,
        ]
    }
}
