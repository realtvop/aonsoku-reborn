package github.realtvop.aonsoku.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * [runCatching] for suspending work: failures become a [Result], but a
 * cancelled coroutine stops here instead of carrying on with a failed result.
 *
 * Plain `runCatching` swallows the cancellation of a load that was superseded
 * by a newer one, and the stale load then goes on to publish its (empty)
 * result over the fresh one.
 */
suspend inline fun <T> runSuspendCatching(block: () -> T): Result<T> {
    val result = try {
        Result.success(block())
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        Result.failure(error)
    }
    currentCoroutineContext().ensureActive()
    return result
}
