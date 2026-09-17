package io.mynote.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FractionalIndexTest {

    @Test
    fun `produces a key between two neighbours`() {
        val a = FractionalIndex.between(null, null)
        val c = FractionalIndex.between(a, null)
        val b = FractionalIndex.between(a, c)
        assertTrue("$a < $b", a < b)
        assertTrue("$b < $c", b < c)
    }

    @Test(timeout = 10_000)
    fun `can always insert at the very front`() {
        // The case that used to hang: nothing sorts below "0", so a key must
        // never end in the lowest digit.
        var first = FractionalIndex.between(null, null)
        repeat(300) {
            val next = FractionalIndex.between(null, first)
            assertTrue("$next should sort before $first", next < first)
            first = next
        }
    }

    @Test(timeout = 10_000)
    fun `can always insert at the very end`() {
        var last = FractionalIndex.between(null, null)
        repeat(300) {
            val next = FractionalIndex.between(last, null)
            assertTrue("$next should sort after $last", next > last)
            last = next
        }
    }

    @Test(timeout = 10_000)
    fun `repeated insertion in the same gap stays ordered`() {
        val low = FractionalIndex.between(null, null)
        var upper = FractionalIndex.between(low, null)
        repeat(300) {
            val mid = FractionalIndex.between(low, upper)
            assertTrue(low < mid)
            assertTrue(mid < upper)
            upper = mid
        }
    }

    @Test
    fun `a generated key never ends in the lowest digit`() {
        var key = FractionalIndex.between(null, null)
        repeat(300) {
            assertNotEquals("key $key ends in 0 — nothing can sort below it", '0', key.last())
            key = FractionalIndex.between(null, key)
        }
    }

    @Test
    fun `keys stay short enough to be practical`() {
        var key = FractionalIndex.between(null, null)
        repeat(300) { key = FractionalIndex.between(null, key) }
        assertTrue("front-insert key grew to ${key.length} characters", key.length < 120)
    }

    @Test
    fun `a generated sequence is strictly increasing`() {
        val keys = FractionalIndex.sequence(50)
        assertEquals(50, keys.size)
        assertEquals(keys.sorted(), keys)
        assertEquals(50, keys.toSet().size)
    }

    @Test
    fun `random interleaved inserts keep a total order`() {
        val keys = FractionalIndex.sequence(10).toMutableList()
        val random = java.util.Random(42)   // fixed seed: a failure is reproducible
        repeat(300) {
            val at = random.nextInt(keys.size + 1)
            val before = keys.getOrNull(at - 1)
            val after = keys.getOrNull(at)
            keys.add(at, FractionalIndex.between(before, after))
        }
        assertEquals("insertion broke the ordering", keys.sorted(), keys)
    }

    @Test
    fun `matches the Swift implementation for the first generated key`() {
        // Both platforms must agree, or the same note would order differently
        // on a phone and a tablet.
        assertEquals("V", FractionalIndex.between(null, null))
        assertEquals("F", FractionalIndex.between(null, "V"))
        assertEquals("k", FractionalIndex.between("V", null))
    }
}
