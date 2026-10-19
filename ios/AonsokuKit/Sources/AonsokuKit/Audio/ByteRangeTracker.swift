import Foundation

struct ByteRangeTracker {
    private(set) var ranges: [Range<Int64>] = []

    var totalBytesDownloaded: Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }

        var merged = range
        var newRanges: [Range<Int64>] = []

        for existing in ranges {
            if existing.upperBound < merged.lowerBound {
                newRanges.append(existing)
            } else if existing.lowerBound > merged.upperBound {
                newRanges.append(merged)
                merged = existing
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }
        newRanges.append(merged)
        ranges = newRanges
    }

    func contains(_ range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        return ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    func isComplete(totalLength: Int64) -> Bool {
        guard totalLength > 0 else { return false }
        return ranges.count == 1 && ranges[0].lowerBound == 0 && ranges[0].upperBound >= totalLength
    }

    func gaps(in range: Range<Int64>) -> [Range<Int64>] {
        guard !range.isEmpty else { return [] }

        var result: [Range<Int64>] = []
        var cursor = range.lowerBound

        for existing in ranges {
            if existing.upperBound <= cursor { continue }
            if existing.lowerBound >= range.upperBound { break }

            let effectiveStart = max(existing.lowerBound, range.lowerBound)
            if cursor < effectiveStart {
                result.append(cursor..<effectiveStart)
            }
            cursor = max(cursor, min(existing.upperBound, range.upperBound))
        }

        if cursor < range.upperBound {
            result.append(cursor..<range.upperBound)
        }

        return result
    }
}
