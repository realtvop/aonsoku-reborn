import Foundation

struct ScrobbleEntry: Codable, Equatable {
    let songId: String
    let playedDurationMs: Int
    let timestamp: Double

    func toDict() -> [String: Any] {
        [
            "songId": songId,
            "playedDurationMs": playedDurationMs,
            "timestamp": timestamp,
        ]
    }
}

protocol ScrobbleEntryStore {
    func load() -> [ScrobbleEntry]
    func save(_ entries: [ScrobbleEntry])
}

final class UserDefaultsScrobbleEntryStore: ScrobbleEntryStore {
    private static let persistenceKey = "com.aonsoku.scrobbleBuffer"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [ScrobbleEntry] {
        guard let data = defaults.data(forKey: Self.persistenceKey) else {
            return []
        }
        return (try? JSONDecoder().decode([ScrobbleEntry].self, from: data)) ?? []
    }

    func save(_ entries: [ScrobbleEntry]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.persistenceKey)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.persistenceKey)
        }
    }
}

class NativeScrobbleBuffer {
    private let store: ScrobbleEntryStore
    private let now: () -> Date
    private var entries: [ScrobbleEntry]
    private var currentSongId: String?
    private var currentSongDuration: Double?
    private var accumulatedMs = 0
    private var segmentStartTime: Date?
    private var trackingStartTimestamp: Double = 0

    init(
        store: ScrobbleEntryStore = UserDefaultsScrobbleEntryStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        self.entries = store.load()
    }

    func startTracking(songId: String, duration: Double = 0) {
        flushCurrent()
        currentSongId = songId
        currentSongDuration = duration
        accumulatedMs = 0
        segmentStartTime = now()
        trackingStartTimestamp = now().timeIntervalSince1970 * 1000
    }

    func pauseTracking() {
        guard segmentStartTime != nil else { return }
        accumulatedMs += currentSegmentMs()
        segmentStartTime = nil
    }

    func resumeTracking() {
        guard currentSongId != nil, segmentStartTime == nil else { return }
        segmentStartTime = now()
    }

    func stopTracking() -> ScrobbleEntry? {
        flushCurrent()
    }

    func getEntries() -> [ScrobbleEntry] {
        entries
    }

    func clear() {
        entries = []
        store.save([])
    }

    func removeEntries(songIds: Set<String>) {
        entries.removeAll { songIds.contains($0.songId) }
        persistEntries()
    }

    func getEntriesAsArray() -> [[String: Any]] {
        entries.map { $0.toDict() }
    }

    private(set) var lastEntryDuration: Double?

    private func currentSegmentMs() -> Int {
        guard let start = segmentStartTime else { return 0 }
        return max(0, Int(now().timeIntervalSince(start) * 1000))
    }

    @discardableResult
    private func flushCurrent() -> ScrobbleEntry? {
        guard let songId = currentSongId else { return nil }

        let totalMs = accumulatedMs + currentSegmentMs()
        let timestamp = trackingStartTimestamp
        let duration = currentSongDuration

        currentSongId = nil
        currentSongDuration = nil
        segmentStartTime = nil
        accumulatedMs = 0

        guard totalMs > 0 else {
            lastEntryDuration = nil
            return nil
        }

        let entry = ScrobbleEntry(
            songId: songId,
            playedDurationMs: totalMs,
            timestamp: timestamp
        )
        entries.append(entry)
        lastEntryDuration = duration
        persistEntries()
        return entry
    }

    private func persistEntries() {
        store.save(entries)
    }
}
