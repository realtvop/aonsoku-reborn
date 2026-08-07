import Foundation

final class NativeLogger {
    static let shared = NativeLogger()

    struct Entry {
        let timestamp: Date
        let level: Level
        let message: String
        let source: String

        enum Level: String, CaseIterable {
            case debug, info, warn, error
        }
    }

    private var buckets: [String: [Entry]] = [:]
    private let maxEntriesPerSource = 200
    private let queue = DispatchQueue(label: "com.aonsoku.NativeLogger")

    private init() {}

    func log(_ level: Entry.Level, _ message: String, source: String = "") {
        #if DEBUG
        if source == "NowPlayingArtwork" || source == "ImageCache" {
            print("[\(source)][\(level.rawValue)] \(message)")
        }
        #endif

        queue.async {
            let entry = Entry(timestamp: Date(), level: level, message: message, source: source)
            let key = source.isEmpty ? "_default" : source
            var bucket = self.buckets[key] ?? []
            if bucket.count >= self.maxEntriesPerSource {
                bucket.removeFirst()
            }
            bucket.append(entry)
            self.buckets[key] = bucket
        }
    }

    func debug(_ message: String, source: String = "") {
        log(.debug, message, source: source)
    }

    func info(_ message: String, source: String = "") {
        log(.info, message, source: source)
    }

    func warn(_ message: String, source: String = "") {
        log(.warn, message, source: source)
    }

    func error(_ message: String, source: String = "") {
        log(.error, message, source: source)
    }

    func getEntries() -> [Entry] {
        queue.sync {
            buckets.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        }
    }

    func clear() {
        queue.async { self.buckets.removeAll() }
    }
}
