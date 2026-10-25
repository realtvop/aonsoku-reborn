package github.realtvop.aonsoku.plugins.data.sync
enum class SyncTier(val freshWindowMs: Long) {
    T1(5 * 60 * 1000L), T2(30 * 60 * 1000L), T3(2 * 60 * 60 * 1000L)
}