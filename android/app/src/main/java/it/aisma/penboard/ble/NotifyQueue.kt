package it.aisma.penboard.ble

import it.aisma.penboard.proto.MAX_POINT_COUNT
import it.aisma.penboard.proto.PenPoint
import it.aisma.penboard.proto.Packets
import it.aisma.penboard.proto.PointEvent

/**
 * Paces outgoing STREAM notifications to the BLE stack's "one in-flight
 * notification" limit (PROTOCOL §2). Points enqueued while a notification is
 * in flight are coalesced into the next batch; if the pending batch would
 * exceed the current MTU-derived capacity, the oldest droppable point
 * (PEN_MOVE/HOVER_MOVE) is dropped first. PEN_DOWN, PEN_UP, HOVER_ENTER and
 * HOVER_EXIT are never dropped.
 *
 * Pure Kotlin aside from the caller-supplied [send] callback, which performs
 * the actual `notifyCharacteristicChanged` call — this keeps the pacing/drop
 * logic unit-testable without a real BluetoothGattServer.
 *
 * Not thread-safe by itself: callers must synchronize on the same instance if
 * [enqueue] and [onNotificationSent] can run on different threads (Android's
 * GATT server callbacks and UI/input threads are not guaranteed to be the
 * same thread).
 */
class NotifyQueue(
    private val maxPointsPerBatch: () -> Int,
    private val send: (ByteArray) -> Boolean,
) {
    private val pending = ArrayDeque<PenPoint>()
    private var inFlight = false
    private var seq = 0

    var droppedPointCount: Int = 0
        private set

    @Synchronized
    fun enqueue(point: PenPoint) {
        pending.addLast(point)
        enforceCapacity()
        flushIfIdle()
    }

    /** Call from the GATT server's onNotificationSent callback. */
    @Synchronized
    fun onNotificationSent() {
        inFlight = false
        flushIfIdle()
    }

    /**
     * Re-attempts a flush after [send] rejected a batch with nothing in
     * flight (stack busy). Unlike [onNotificationSent], never clears an
     * in-flight notification, so it can't break the one-in-flight pacing.
     */
    @Synchronized
    fun retry() {
        flushIfIdle()
    }

    @Synchronized
    fun pendingCount(): Int = pending.size

    /**
     * Drops every buffered point without sending it. Called when the STREAM
     * gate transitions closed -> open (PenGattServer, PROTOCOL §6.8): points
     * captured before the handshake completed are stale by the time the gate
     * opens and would otherwise flush as a phantom burst.
     */
    @Synchronized
    fun clear() {
        pending.clear()
    }

    private fun enforceCapacity() {
        val cap = maxPointsPerBatch().coerceIn(1, MAX_POINT_COUNT)
        while (pending.size > cap) {
            val dropIndex = pending.indexOfFirst { !PointEvent.isCritical(it.event) }
            if (dropIndex == -1) break // only critical events left; let the batch run over cap.
            pending.removeAt(dropIndex)
            droppedPointCount++
        }
    }

    private fun flushIfIdle() {
        if (inFlight || pending.isEmpty()) return
        val cap = maxPointsPerBatch().coerceIn(1, MAX_POINT_COUNT)
        val batchSize = minOf(cap, pending.size)
        val batch = ArrayList<PenPoint>(batchSize)
        repeat(batchSize) { batch.add(pending.removeFirst()) }

        val bytes = Packets.encodePointBatch(seq, batch)
        val accepted = send(bytes)
        if (accepted) {
            seq = (seq + 1) and 0xFFFF
            inFlight = true
        } else {
            // Stack rejected the notify outright (e.g. not subscribed yet, or
            // busy): put the batch back at the front and try again on the next
            // enqueue/onNotificationSent, without losing points or advancing seq.
            for (i in batch.indices.reversed()) {
                pending.addFirst(batch[i])
            }
        }
    }
}
