package it.aisma.penboard.ble

import it.aisma.penboard.proto.DecodeResult
import it.aisma.penboard.proto.PenPoint
import it.aisma.penboard.proto.Packets
import it.aisma.penboard.proto.PointEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotifyQueueTest {

    private fun move(x: Int) = PenPoint(x, 0, 0, PenPoint.flagsOf(PointEvent.PEN_MOVE))

    private fun decodeBatch(bytes: ByteArray): List<PenPoint> {
        val result = Packets.decode(bytes)
        check(result is DecodeResult.PointBatch)
        return result.packet.points
    }

    @Test
    fun `single point flushes immediately when idle`() {
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 25 }, send = { sent.add(it); true })

        queue.enqueue(move(1))

        assertEquals(1, sent.size)
        assertEquals(listOf(1), decodeBatch(sent[0]).map { it.x })
    }

    @Test
    fun `points enqueued while in flight coalesce into the next batch`() {
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 25 }, send = { sent.add(it); true })

        queue.enqueue(move(1)) // sent immediately, now "in flight"
        queue.enqueue(move(2)) // coalesced, queue is busy
        queue.enqueue(move(3)) // coalesced

        assertEquals(1, sent.size) // still only the first notification went out
        assertEquals(2, queue.pendingCount())

        queue.onNotificationSent() // first notification completes -> flush coalesced batch

        assertEquals(2, sent.size)
        assertEquals(listOf(2, 3), decodeBatch(sent[1]).map { it.x })
        assertEquals(0, queue.pendingCount())
    }

    @Test
    fun `oldest PEN_MOVE is dropped first when the pending batch exceeds capacity`() {
        val sent = mutableListOf<ByteArray>()
        // Cap batches at 2 points, and keep one notification permanently "in
        // flight" by never calling onNotificationSent, so every enqueue after
        // the first coalesces into the single pending batch under test.
        val queue = NotifyQueue(maxPointsPerBatch = { 2 }, send = { sent.add(it); true })

        queue.enqueue(move(1)) // sent immediately (batch of 1), now in flight
        queue.enqueue(move(2)) // pending: [2]
        queue.enqueue(move(3)) // pending: [2,3] (at cap)
        queue.enqueue(move(4)) // pending would be [2,3,4] (over cap) -> drop oldest movable (2)

        assertEquals(1, sent.size) // nothing new sent yet, still in flight
        assertEquals(2, queue.pendingCount())
        assertEquals(1, queue.droppedPointCount)

        queue.onNotificationSent()

        assertEquals(2, sent.size)
        assertEquals(listOf(3, 4), decodeBatch(sent[1]).map { it.x })
    }

    @Test
    fun `PEN_DOWN, PEN_UP, HOVER_ENTER and HOVER_EXIT are never dropped`() {
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 2 }, send = { sent.add(it); true })

        val down = PenPoint(10, 0, 0, PenPoint.flagsOf(PointEvent.PEN_DOWN))
        val up = PenPoint(20, 0, 0, PenPoint.flagsOf(PointEvent.PEN_UP))
        val hoverEnter = PenPoint(30, 0, 0, PenPoint.flagsOf(PointEvent.HOVER_ENTER))
        val hoverExit = PenPoint(40, 0, 0, PenPoint.flagsOf(PointEvent.HOVER_EXIT))

        queue.enqueue(down) // sent immediately, now in flight
        queue.enqueue(up) // pending: [up]
        queue.enqueue(hoverEnter) // pending: [up, hoverEnter] (at cap of 2)
        queue.enqueue(hoverExit) // over cap, but nothing droppable -> queue grows past cap

        assertEquals(0, queue.droppedPointCount)
        assertEquals(3, queue.pendingCount())

        // Draining never packs more points into one notification than the
        // current cap allows (that would violate the MTU-derived payload
        // limit) -- it just refuses to drop critical events, so they spill
        // into a follow-up batch instead of one oversized notification.
        queue.onNotificationSent()
        queue.onNotificationSent()

        assertEquals(0, queue.droppedPointCount)
        assertEquals(3, sent.size)
        val deliveredXs = sent.drop(1).flatMap { decodeBatch(it).map { p -> p.x } }
        assertEquals(listOf(20, 30, 40), deliveredXs)
    }

    @Test
    fun `a rejected send is requeued without advancing sequence`() {
        var accept = false
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 25 }, send = { if (accept) { sent.add(it); true } else false })

        queue.enqueue(move(1)) // rejected (not subscribed yet, say) -> requeued

        assertEquals(0, sent.size)
        assertEquals(1, queue.pendingCount())

        accept = true
        queue.enqueue(move(2)) // retries the flush, now accepted with both points

        assertEquals(1, sent.size)
        assertEquals(listOf(1, 2), decodeBatch(sent[0]).map { it.x })
    }

    @Test
    fun `clear drops buffered points without sending them`() {
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 25 }, send = { sent.add(it); true })

        queue.enqueue(move(1)) // sent immediately, now "in flight"
        queue.enqueue(move(2)) // coalesced: pending=[2]
        queue.enqueue(move(3)) // coalesced: pending=[2,3]

        queue.clear()
        assertEquals(0, queue.pendingCount())

        queue.onNotificationSent() // in-flight notification completes; nothing left to flush
        assertEquals(1, sent.size) // only the original notification ever went out
    }

    @Test
    fun `a raised MTU cap lets more coalesced points ship in a single batch`() {
        var cap = 1
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { cap }, send = { sent.add(it); true })

        queue.enqueue(move(1)) // cap=1: sent immediately as its own batch, now in flight
        cap = 25 // onMtuChanged fires before the in-flight notification completes
        queue.enqueue(move(2)) // coalesces: pending=[2]
        queue.enqueue(move(3)) // coalesces: pending=[2,3], within the new cap of 25

        assertEquals(1, sent.size) // still just the first notification

        queue.onNotificationSent() // flush now uses the raised cap

        assertEquals(2, sent.size)
        assertEquals(listOf(2, 3), decodeBatch(sent[1]).map { it.x })
    }

    @Test
    fun `retry re-sends a batch the stack rejected without advancing seq`() {
        var accept = false
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 25 }, send = { if (accept) sent.add(it); accept })

        queue.enqueue(move(1)) // stack busy: rejected, kept pending
        assertEquals(0, sent.size)
        assertEquals(1, queue.pendingCount())

        accept = true
        queue.retry()

        assertEquals(1, sent.size)
        assertEquals(listOf(1), decodeBatch(sent[0]).map { it.x })
        assertEquals(0, (Packets.decode(sent[0]) as DecodeResult.PointBatch).packet.seq)
    }

    @Test
    fun `retry never sends while a notification is still in flight`() {
        val sent = mutableListOf<ByteArray>()
        val queue = NotifyQueue(maxPointsPerBatch = { 25 }, send = { sent.add(it); true })

        queue.enqueue(move(1)) // in flight
        queue.enqueue(move(2)) // pending
        queue.retry()

        assertEquals(1, sent.size)
        assertEquals(1, queue.pendingCount())
    }
}
