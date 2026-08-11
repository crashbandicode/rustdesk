package com.carriez.flutter_hbb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImeStateDispatchCoordinatorTest {
    @Test
    fun `provisional edits are coalesced`() {
        val events = mutableListOf<String>()
        val dispatch = coordinator(events)

        dispatch.schedule()
        dispatch.schedule()

        assertEquals(listOf("cancel", "post", "cancel", "post"), events)
    }

    @Test
    fun `commit boundary cancels a provisional callback and emits immediately`() {
        val events = mutableListOf<String>()
        val dispatch = coordinator(events)

        dispatch.schedule()
        assertTrue(dispatch.commitBoundary(true))
        assertFalse(dispatch.commitBoundary(false))

        assertEquals(
            listOf("cancel", "post", "cancel", "emit", "cancel", "emit"),
            events
        )
    }

    private fun coordinator(events: MutableList<String>) =
        ImeStateDispatchCoordinator(
            cancelPending = { events.add("cancel") },
            postPending = { events.add("post") },
            emitNow = { events.add("emit") }
        )
}
