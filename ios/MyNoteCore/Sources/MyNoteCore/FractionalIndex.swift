import Foundation

/// Ordering keys for blocks and notes.
///
/// Storing an integer `position` would mean rewriting every row below an insert,
/// and two offline devices inserting at the same spot would collide. A fractional
/// index instead generates a *string* strictly between its neighbours, so an
/// insert touches exactly one row and concurrent inserts merely interleave.
///
/// Invariant: **a generated key never ends in the lowest digit ('0')**.
/// Without it there is no key below `"0"` — `"00"` sorts *after* `"0"` — and
/// `between(nil, "0")` has no answer, so repeatedly inserting at the top would
/// eventually wedge. Keeping the last digit non-zero guarantees there is always
/// room below any existing key.
public enum FractionalIndex {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let base = digits.count

    /// Depth guard. Keys grow by one character per exhausted gap, so real use
    /// stays far below this; hitting it means a caller passed `a >= b`, and
    /// returning a usable key beats hanging the editor.
    static let maxDepth = 512

    private static func index(of ch: Character) -> Int? {
        digits.firstIndex(of: ch)
    }

    /// A key strictly between `a` and `b`. `nil` means "no neighbour on that side".
    ///
    /// Precondition: if both are given, `a < b`.
    /// Invalid input (`a >= b`, or a `b` that violates the trailing-digit
    /// invariant) yields a best-effort key rather than a crash or a hang. The
    /// server rejects malformed order keys at the boundary, so reaching this is
    /// already a bug elsewhere — and mis-ordering one block beats killing the
    /// editor while someone is writing. Kotlin behaves identically.
    public static func between(_ a: String?, _ b: String?) -> String {
        let lower = Array(a ?? "")
        var upper: [Character]? = b.map(Array.init)
        var result = ""
        var i = 0

        while i < maxDepth {
            let ca: Int? = i < lower.count ? index(of: lower[i]) : nil

            // `base` means "unconstrained above"; 0 means b has run out or holds
            // the lowest digit, and either way there is no room at this position.
            let cb: Int
            if let up = upper {
                cb = i < up.count ? (index(of: up[i]) ?? 0) : 0
            } else {
                cb = base
            }

            guard let ca else {
                // `a` has run out: anything we append already sorts after it, so
                // we only have to stay below `b`.
                if cb > 1 {
                    result.append(digits[cb / 2])   // >= 1, so never a trailing '0'
                    return result
                }
                // cb is 0 or 1: no room here, so step down a level.
                result.append(digits[0])
                // Placing '0' under b's '1' puts us strictly below b already,
                // which frees the rest of the suffix.
                if cb == 1 { upper = nil }
                i += 1
                continue
            }

            if cb - ca > 1 {
                result.append(digits[(ca + cb) / 2])   // > ca, so never '0'
                return result
            }

            result.append(digits[ca])
            if ca < cb { upper = nil }   // diverged below `b`; suffix is now free
            i += 1
        }

        // Unreachable for valid input; keeps a bad call from hanging.
        result.append(digits[base / 2])
        return result
    }

    /// Evenly spaced keys for an initial batch.
    public static func sequence(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var keys: [String] = []
        var previous: String? = nil
        for _ in 0..<count {
            let key = between(previous, nil)
            keys.append(key)
            previous = key
        }
        return keys
    }
}
