import Foundation

/// §9.1 message-ID dedup cache for incoming envelopes (design §9.1).
///
/// The server replays the original result for a replayed messageId, so a
/// duplicate here is expected — the caller must skip re-dispatching it.
/// Bounded to `max` entries; the oldest entry is evicted when the cap is
/// reached (insertion-ordered `OrderedDictionary`-ish behavior via a
/// simple dictionary + insertion-order array).
public final class CoordinationDedup: @unchecked Sendable {
    private let max: Int
    private var seen: [String: TimeInterval] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    public init(max: Int = 200) {
        self.max = max
    }

    /// Returns true if `id` was already seen (duplicate).
    public func has(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen[id] != nil
    }

    /// Mark `id` as seen. Evicts the oldest entry when full.
    public func mark(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if seen[id] != nil { return }
        if order.count >= max, let oldest = order.first {
            seen.removeValue(forKey: oldest)
            order.removeFirst()
        }
        seen[id] = Date().timeIntervalSince1970
        order.append(id)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        seen.removeAll()
        order.removeAll()
    }

    public func size() -> Int {
        lock.lock(); defer { lock.unlock() }
        return seen.count
    }
}

/// §9.2 sequence tracker — keeps the highest server seq the client has
/// processed so the next `connect()` can submit `lastSeq` and the server
/// can skip already-delivered messages.
public final class CoordinationSeqTracker: @unchecked Sendable {
    private var lastSeq: Int64 = 0
    private let lock = NSLock()

    public init() {}

    /// Update the tracker with an incoming seq. Only increases.
    public func observe(_ seq: Int64?) {
        guard let seq else { return }
        lock.lock(); defer { lock.unlock() }
        if seq > lastSeq { lastSeq = seq }
    }

    public func get() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return lastSeq
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        lastSeq = 0
    }
}