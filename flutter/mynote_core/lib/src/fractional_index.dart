/// Ordering keys for blocks and notes — the Dart twin of `FractionalIndex.kt`
/// and `FractionalIndex.swift`.
///
/// Storing an integer position would mean rewriting every row below an insert,
/// and two offline devices inserting at the same spot would collide. A
/// fractional index generates a *string* strictly between its neighbours, so an
/// insert touches one row and concurrent inserts merely interleave.
///
/// Invariant: **a generated key never ends in the lowest digit ('0')**. Without
/// it there is no key below `"0"` (`"00"` sorts *after* `"0"`), so inserting at
/// the top repeatedly would eventually have no answer. That one bug looped
/// forever and hung a test suite for fourteen minutes.
abstract final class FractionalIndex {
  static const String _digits =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  static final int _base = _digits.length;

  /// Depth guard: a bad call must not hang the editor.
  static const int _maxDepth = 512;

  /// A key strictly between [a] and [b]. `null` means "no neighbour on that
  /// side". Requires `a < b` when both are given.
  ///
  /// Invalid input (`a >= b`, or a `b` violating the trailing-digit invariant)
  /// yields a best-effort key rather than throwing: reaching it is already a
  /// bug elsewhere, and mis-ordering one block beats crashing the editor while
  /// someone is writing. Swift and Kotlin behave identically.
  static String between(String? a, String? b) {
    final lower = a ?? '';
    String? upper = b;
    final result = StringBuffer();
    var i = 0;

    while (i < _maxDepth) {
      int? ca;
      if (i < lower.length) {
        final index = _digits.indexOf(lower[i]);
        ca = index >= 0 ? index : null;
      }

      // _base means "unconstrained above"; 0 means b ran out or holds the
      // lowest digit, and either way there is no room at this position.
      final int cb;
      if (upper == null) {
        cb = _base;
      } else if (i < upper.length) {
        final index = _digits.indexOf(upper[i]);
        cb = index < 0 ? 0 : index;
      } else {
        cb = 0;
      }

      if (ca == null) {
        // `a` ran out: anything appended already sorts after it, so we only
        // have to stay below `b`.
        if (cb > 1) {
          result.write(_digits[cb ~/ 2]); // >= 1, never a trailing '0'
          return result.toString();
        }
        result.write(_digits[0]);
        // Placing '0' under b's '1' puts us strictly below b already.
        if (cb == 1) upper = null;
        i++;
        continue;
      }

      if (cb - ca > 1) {
        result.write(_digits[(ca + cb) ~/ 2]); // > ca, never '0'
        return result.toString();
      }

      result.write(_digits[ca]);
      if (ca < cb) upper = null; // diverged below b; the suffix is now free
      i++;
    }

    result.write(_digits[_base ~/ 2]);
    return result.toString();
  }

  static List<String> sequence(int count) {
    final keys = <String>[];
    String? previous;
    for (var i = 0; i < count; i++) {
      final key = between(previous, null);
      keys.add(key);
      previous = key;
    }
    return keys;
  }
}
