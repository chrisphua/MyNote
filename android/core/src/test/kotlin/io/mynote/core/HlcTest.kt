package io.mynote.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HlcTest {

    /**
     * Shared vectors.
     *
     * The same pairs are asserted in `backend/test/hlc.test.ts` and
     * `HybridLogicalClockTests`. If any implementation drifts, conflict
     * resolution silently picks the wrong winner, so this is the guard.
     */
    @Test
    fun `encoding matches the cross-platform format`() {
        assertEquals(
            "0000018f5a2b3c4d-0007-deviceA",
            Hlc(millis = 0x18f5a2b3c4d, counter = 7, node = "deviceA").encoded(),
        )
        assertEquals(
            "0000000000000000-0000-a",
            Hlc(millis = 0, counter = 0, node = "a").encoded(),
        )
        assertEquals(
            "00000000000003e8-ffff-node-with-dashes",
            Hlc(millis = 1000, counter = 0xffff, node = "node-with-dashes").encoded(),
        )
    }

    @Test
    fun `round-trips through decode`() {
        val hlc = Hlc(1_700_000_000_000, 7, "deviceA")
        assertEquals(hlc, Hlc.decode(hlc.encoded()))
    }

    @Test
    fun `node ids containing dashes survive decoding`() {
        val hlc = Hlc(123, 4, "abc-def-ghi")
        assertEquals("abc-def-ghi", Hlc.decode(hlc.encoded())?.node)
    }

    @Test
    fun `sorts lexicographically in time order`() {
        val early = Hlc(1_700_000_000_000, 0, "a").encoded()
        val later = Hlc(1_700_000_000_001, 0, "a").encoded()
        assertTrue(early < later)
        assertEquals(listOf(early, later), listOf(later, early).sorted())
    }

    @Test
    fun `breaks ties within a millisecond by counter`() {
        assertTrue(Hlc(100, 0, "a").encoded() < Hlc(100, 1, "a").encoded())
    }

    @Test
    fun `keeps advancing when the device clock goes backwards`() {
        // A phone that resyncs NTP can jump backwards; our own edits must still
        // be strictly increasing or the newer one would lose.
        val start = Hlc(1000, 0, "a")
        val next = start.tick(500)
        assertTrue(next.encoded() > start.encoded())
    }

    @Test
    fun `steps the clock rather than wrapping the counter`() {
        val saturated = Hlc(1000, Hlc.MAX_COUNTER, "a")
        val next = saturated.tick(1000)
        assertEquals(1001L, next.millis)
        assertEquals(0, next.counter)
        assertTrue(next.encoded() > saturated.encoded())
    }

    @Test
    fun `never lags behind a clock it has seen`() {
        val local = Hlc(1000, 0, "a")
        val remote = Hlc(5000, 3, "b")
        val merged = local.observe(remote, 1001)
        assertEquals(5000L, merged.millis)
        assertTrue(merged.encoded() > remote.encoded())
    }

    @Test
    fun `rejects a clock implausibly far in the future`() {
        val now = System.currentTimeMillis()
        assertTrue(Hlc.isPlausible(Hlc(now, 0, "a").encoded(), now))
        assertFalse(Hlc.isPlausible(Hlc(now + 90L * 24 * 3600 * 1000, 0, "a").encoded(), now))
        assertFalse(Hlc.isPlausible("not-an-hlc", now))
        assertNull(Hlc.decode("garbage"))
    }

    @Test
    fun `500 successive stamps are strictly increasing`() {
        var clock = Hlc(1000, 0, "a")
        var previous = ""
        repeat(500) {
            clock = clock.tick(1000)   // frozen clock: worst case for monotonicity
            val encoded = clock.encoded()
            assertTrue("$encoded not greater than $previous", encoded > previous)
            previous = encoded
        }
    }
}

class HlcOverflowTest {
    @Test
    fun `merge carries the counter into millis rather than widening the field`() {
        // A peer can legitimately send counter = ffff. Incrementing past it would
        // encode five hex digits and break the fixed-width ordering the server's
        // SQL `>` depends on, making every later comparison wrong.
        val local = Hlc(1000, Hlc.MAX_COUNTER, "a")
        val remote = Hlc(1000, Hlc.MAX_COUNTER, "b")
        val merged = local.observe(remote, 1000)

        assertTrue(merged.counter <= Hlc.MAX_COUNTER)
        assertEquals(4, merged.encoded().split("-")[1].length)
        assertTrue(merged.encoded() > local.encoded())
    }
}
