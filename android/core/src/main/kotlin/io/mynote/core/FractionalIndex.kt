package io.mynote.core

/**
 * Ordering keys for blocks and notes — the Kotlin twin of `FractionalIndex.swift`.
 *
 * Storing an integer position would mean rewriting every row below an insert, and
 * two offline devices inserting at the same spot would collide. A fractional index
 * generates a *string* strictly between its neighbours, so an insert touches one
 * row and concurrent inserts merely interleave.
 *
 * Invariant: **a generated key never ends in the lowest digit ('0')**. Without it
 * there is no key below `"0"` (`"00"` sorts *after* `"0"`), so inserting at the top
 * repeatedly would eventually have no answer.
 */
object FractionalIndex {
    private const val DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    private val BASE = DIGITS.length

    /** Depth guard: a bad call must not hang the editor. */
    private const val MAX_DEPTH = 512

    /**
     * A key strictly between [a] and [b]. `null` means "no neighbour on that side".
     *
     * Requires `a < b` when both are given.
     */
    fun between(a: String?, b: String?): String {
        // Invalid input (`a >= b`, or a `b` violating the trailing-digit
        // invariant) yields a best-effort key rather than an exception. The
        // server rejects malformed order keys at the boundary, so reaching this
        // is already a bug elsewhere — and mis-ordering one block beats crashing
        // the editor while someone is writing. Swift behaves identically.
        val lower = a ?: ""
        var upper: String? = b
        val result = StringBuilder()
        var i = 0

        while (i < MAX_DEPTH) {
            val ca: Int? = if (i < lower.length) DIGITS.indexOf(lower[i]).takeIf { it >= 0 } else null

            // BASE means "unconstrained above"; 0 means b ran out or holds the
            // lowest digit, and either way there is no room at this position.
            val cb: Int = upper?.let { up ->
                if (i < up.length) DIGITS.indexOf(up[i]).coerceAtLeast(0) else 0
            } ?: BASE

            if (ca == null) {
                // `a` ran out: anything appended already sorts after it, so we
                // only have to stay below `b`.
                if (cb > 1) {
                    result.append(DIGITS[cb / 2])   // >= 1, never a trailing '0'
                    return result.toString()
                }
                result.append(DIGITS[0])
                // Placing '0' under b's '1' puts us strictly below b already.
                if (cb == 1) upper = null
                i++
                continue
            }

            if (cb - ca > 1) {
                result.append(DIGITS[(ca + cb) / 2])   // > ca, never '0'
                return result.toString()
            }

            result.append(DIGITS[ca])
            if (ca < cb) upper = null   // diverged below b; suffix is now free
            i++
        }

        result.append(DIGITS[BASE / 2])
        return result.toString()
    }

    fun sequence(count: Int): List<String> {
        val keys = mutableListOf<String>()
        var previous: String? = null
        repeat(count) {
            val key = between(previous, null)
            keys += key
            previous = key
        }
        return keys
    }
}
