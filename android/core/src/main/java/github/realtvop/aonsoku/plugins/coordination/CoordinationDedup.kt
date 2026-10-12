package github.realtvop.aonsoku.plugins.coordination

import java.util.LinkedHashMap

/// §9.1 message-ID dedup cache for incoming envelopes.
///
/// The server replays the original result for a replayed messageId, so a
/// duplicate here is expected — the caller must skip re-dispatching it.
/// The cache is bounded to [max] entries; the oldest entry is evicted
/// when the cap is reached (LRU-ish, insertion-ordered via `LinkedHashMap`
/// with access-order disabled so iteration yields the oldest first).
internal class CoordinationDedup(private val max: Int = 200) {
    private val seen: MutableMap<String, Long> =
        object : LinkedHashMap<String, Long>(max, 0.75f, false) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Long>?): Boolean {
                return size > max
            }
        }

    /// Returns true if [id] was already seen (duplicate).
    fun has(id: String): Boolean = synchronized(seen) { seen.containsKey(id) }

    /// Mark [id] as seen. Evicts the oldest entry when full.
    fun mark(id: String) {
        synchronized(seen) {
            if (!seen.containsKey(id)) seen[id] = System.currentTimeMillis()
        }
    }

    fun clear() {
        synchronized(seen) { seen.clear() }
    }

    fun size(): Int = synchronized(seen) { seen.size }
}

/// §9.2 sequence tracker — keeps the highest server seq the client has
/// processed so the next `connect()` can submit `lastSeq` and the server
/// can skip already-delivered messages.
internal class CoordinationSeqTracker {
    @Volatile
    private var lastSeq: Long = 0L

    /// Update the tracker with an incoming seq. Only increases.
    fun observe(seq: Long?) {
        if (seq == null) return
        if (seq > lastSeq) lastSeq = seq
    }

    fun get(): Long = lastSeq

    fun reset() {
        lastSeq = 0L
    }
}