package io.mynote.core

/**
 * Hybrid Logical Clock — must encode byte-for-byte identically to
 * `backend/src/hlc.ts` and `HybridLogicalClock.swift`.
 *
 * The server resolves conflicts with a plain SQL `>` on this encoded string, so
 * any disagreement between the three implementations would silently pick the
 * wrong winner. The shared test vectors in `HlcTest` guard that.
 */
data class Hlc(
    val millis: Long,
    val counter: Int = 0,
    val node: String,
) {
    /** `0000018f5a2b3c4d-0000-node` — fixed width so lexicographic order is time order. */
    fun encoded(): String =
        "%016x-%04x-%s".format(millis, counter, node)

    fun tick(now: Long): Hlc = when {
        now > millis -> copy(millis = now, counter = 0)
        // >65k edits in one millisecond: step the clock rather than wrap.
        counter >= MAX_COUNTER -> copy(millis = millis + 1, counter = 0)
        else -> copy(counter = counter + 1)
    }

    /** Merge a clock we received, so we never issue an edit that sorts older. */
    fun observe(remote: Hlc, now: Long): Hlc {
        val maxMillis = maxOf(millis, remote.millis, now)
        return when {
            maxMillis == millis && maxMillis == remote.millis ->
                copy(millis = maxMillis, counter = maxOf(counter, remote.counter) + 1)
            maxMillis == millis -> copy(millis = maxMillis, counter = counter + 1)
            maxMillis == remote.millis -> copy(millis = maxMillis, counter = remote.counter + 1)
            else -> copy(millis = maxMillis, counter = 0)
        }
    }

    companion object {
        const val MAX_COUNTER = 0xffff

        /** Reject clocks far enough in the future to win every later conflict. */
        const val MAX_CLOCK_SKEW_MS = 24L * 60 * 60 * 1000

        fun decode(s: String): Hlc? {
            val parts = s.split("-", limit = 3)
            if (parts.size != 3) return null
            val millis = parts[0].toLongOrNull(16) ?: return null
            val counter = parts[1].toIntOrNull(16) ?: return null
            return Hlc(millis, counter, parts[2])
        }

        fun now(node: String): Hlc = Hlc(System.currentTimeMillis(), 0, node)

        fun isPlausible(encoded: String, now: Long): Boolean {
            val hlc = decode(encoded) ?: return false
            return hlc.millis <= now + MAX_CLOCK_SKEW_MS
        }
    }
}
