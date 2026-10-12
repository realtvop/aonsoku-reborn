package github.realtvop.aonsoku.plugins.debug

import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

object NativeLogger {
    data class Entry(
        val timestamp: Long,
        val level: Level,
        val message: String,
        val source: String
    ) {
        enum class Level { DEBUG, INFO, WARN, ERROR }
    }

    private const val MAX_ENTRIES_PER_SOURCE = 200
    private val buckets = mutableMapOf<String, MutableList<Entry>>()
    private val lock = ReentrantReadWriteLock()

    fun log(level: Entry.Level, message: String, source: String = "") {
        val entry = Entry(System.currentTimeMillis(), level, message, source)
        val key = source.ifEmpty { "_default" }
        lock.write {
            val bucket = buckets.getOrPut(key) { mutableListOf() }
            if (bucket.size >= MAX_ENTRIES_PER_SOURCE) {
                bucket.removeFirst()
            }
            bucket.add(entry)
        }
        val tag = "Aonsoku/${source.ifEmpty { "Default" }}"
        when (level) {
            Entry.Level.DEBUG -> android.util.Log.d(tag, message)
            Entry.Level.INFO -> android.util.Log.i(tag, message)
            Entry.Level.WARN -> android.util.Log.w(tag, message)
            Entry.Level.ERROR -> android.util.Log.e(tag, message)
        }
    }

    fun debug(message: String, source: String = "") = log(Entry.Level.DEBUG, message, source)
    fun info(message: String, source: String = "") = log(Entry.Level.INFO, message, source)
    fun warn(message: String, source: String = "") = log(Entry.Level.WARN, message, source)
    fun error(message: String, source: String = "") = log(Entry.Level.ERROR, message, source)

    fun getEntries(): List<Entry> {
        return lock.read {
            buckets.values.flatten().sortedBy { it.timestamp }
        }
    }

    fun clear() {
        lock.write { buckets.clear() }
    }
}
