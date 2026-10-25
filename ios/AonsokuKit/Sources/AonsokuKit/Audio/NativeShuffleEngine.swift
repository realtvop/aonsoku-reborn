import Foundation

class NativeShuffleEngine {
    func shuffleWithGapAvoidance(_ songs: [QueueSong], history: [String]) -> [QueueSong] {
        if history.isEmpty {
            var result = songs
            fisherYatesInPlace(&result)
            return result
        }

        let historyIndex = Dictionary(
            history.enumerated().map { ($1, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var fresh: [QueueSong] = []
        var recent: [QueueSong] = []

        for song in songs {
            if historyIndex[song.id] != nil {
                recent.append(song)
            } else {
                fresh.append(song)
            }
        }

        fisherYatesInPlace(&fresh)
        recent.sort { (historyIndex[$0.id] ?? 0) < (historyIndex[$1.id] ?? 0) }

        return fresh + recent
    }

    func pickRandomStartIndex(
        count: Int,
        startHistory: [String],
        getId: (Int) -> String
    ) -> Int {
        guard count > 0 else { return 0 }

        let historySet = Set(startHistory)
        let maxAttempts = min(count, startHistory.count + 10)

        for _ in 0..<maxAttempts {
            let idx = Int.random(in: 0..<count)
            if !historySet.contains(getId(idx)) { return idx }
        }

        for i in 0..<count {
            if !historySet.contains(getId(i)) { return i }
        }

        return Int.random(in: 0..<count)
    }

    func pushToHistory(_ history: [String], id: String, maxLen: Int) -> [String] {
        var result = history.filter { $0 != id }
        result.append(id)
        if result.count > maxLen {
            result = Array(result.suffix(maxLen))
        }
        return result
    }

    private func fisherYatesInPlace<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            array.swapAt(i, j)
        }
    }
}
