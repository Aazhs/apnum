package dev.apnum.android.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** One thing that syncs: its Mac `changed` topic, the sync call and a flow of local edits. */
class SyncJob(val topic: String, val edits: Flow<Unit>, val run: suspend () -> SyncResult)

/**
 * Decides when to sync: when the Mac becomes available, shortly after a local edit, and when the Mac says its
 * data changed. A failed round is retried every [retryMs] while still connected; offline edits wait in the
 * store until the next connect.
 */
class SyncCoordinator(
    private val scope: CoroutineScope,
    private val jobs: List<SyncJob>,
    /** True while connected and the Mac has told us its tools. */
    private val available: Flow<Boolean>,
    /** Topics of the Mac's `changed` events. */
    private val macChanges: Flow<String>,
    private val retryMs: Long = 15_000,
    private val debounceMs: Long = 300,
    private val quietMs: Long = 1_000,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val onResult: (String, SyncResult) -> Unit = { _, _ -> },
) {
    private class Worker(val job: SyncJob, val trigger: Channel<Unit> = Channel(Channel.CONFLATED), @Volatile var lastDoneMs: Long = Long.MIN_VALUE / 2)

    fun start() {
        val workers = jobs.map { Worker(it) }
        for (w in workers) {
            scope.launch {
                for (ignored in w.trigger) {
                    var r = w.job.run()
                    onResult(w.job.topic, r)
                    while (r is SyncResult.Failed) {
                        delay(retryMs)
                        r = w.job.run()
                        onResult(w.job.topic, r)
                    }
                    w.lastDoneMs = nowMs()
                }
            }
            scope.launch { w.job.edits.collectLatest { delay(debounceMs); w.trigger.trySend(Unit) } }
        }
        scope.launch { available.collect { if (it) workers.forEach { w -> w.trigger.trySend(Unit) } } }
        scope.launch {
            macChanges.collect { topic ->
                workers.filter { it.job.topic == topic && nowMs() - it.lastDoneMs > quietMs }.forEach { it.trigger.trySend(Unit) }
            }
        }
    }
}
