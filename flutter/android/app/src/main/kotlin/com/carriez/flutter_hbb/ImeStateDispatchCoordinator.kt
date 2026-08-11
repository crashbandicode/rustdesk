package com.carriez.flutter_hbb

/**
 * Coalesces provisional IME edits while preserving semantic commit boundaries.
 *
 * Gboard may commit an accepted suggestion and start the next composing span in
 * the same Android event-loop turn. If both states are posted through one
 * debounced callback, the committed state is canceled and the remote side never
 * receives the correction. Commit boundaries therefore cancel the pending
 * provisional callback and emit the current editor state immediately.
 */
internal class ImeStateDispatchCoordinator(
    private val cancelPending: () -> Unit,
    private val postPending: () -> Unit,
    private val emitNow: () -> Unit
) {
    fun schedule() {
        cancelPending()
        postPending()
    }

    fun commitBoundary(result: Boolean): Boolean {
        cancelPending()
        emitNow()
        return result
    }
}
