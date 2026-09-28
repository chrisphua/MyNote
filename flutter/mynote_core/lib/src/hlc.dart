/// Hybrid Logical Clock.
///
/// The Dart twin of `Hlc.kt` and `HybridLogicalClock.swift`. Conflict
/// resolution is a plain string comparison on [encoded], so any disagreement
/// between implementations silently picks the wrong winner. The shared vectors
/// in `test/hlc_test.dart` are the guard, and they are the same pairs the
/// Kotlin and Swift suites assert.
class Hlc {
  const Hlc({required this.millis, this.counter = 0, required this.node});

  final int millis;
  final int counter;
  final String node;

  static const int maxCounter = 0xffff;

  /// Reject clocks far enough ahead to win every later conflict.
  static const int maxClockSkewMs = 24 * 60 * 60 * 1000;

  /// `0000018f5a2b3c4d-0000-node` — fixed width, so lexicographic order is
  /// time order.
  String encoded() =>
      '${millis.toRadixString(16).padLeft(16, '0')}-'
      '${counter.toRadixString(16).padLeft(4, '0')}-'
      '$node';

  Hlc tick(int now) {
    if (now > millis) return Hlc(millis: now, node: node);
    // >65k edits in one millisecond: step the clock rather than wrap.
    if (counter >= maxCounter) return Hlc(millis: millis + 1, node: node);
    return Hlc(millis: millis, counter: counter + 1, node: node);
  }

  /// Merge a clock we received, so we never issue an edit that sorts older.
  ///
  /// The counter carries into millis on overflow exactly as [tick] does. A peer
  /// can legitimately send `counter = ffff`, and incrementing past it would
  /// encode a five-digit counter field — silently breaking the fixed-width
  /// ordering the comparison depends on.
  Hlc observe(Hlc remote, int now) {
    final maxMillis = [millis, remote.millis, now].reduce((a, b) => a > b ? a : b);
    final int next;
    if (maxMillis == millis && maxMillis == remote.millis) {
      next = (counter > remote.counter ? counter : remote.counter) + 1;
    } else if (maxMillis == millis) {
      next = counter + 1;
    } else if (maxMillis == remote.millis) {
      next = remote.counter + 1;
    } else {
      next = 0;
    }
    if (next > maxCounter) return Hlc(millis: maxMillis + 1, node: node);
    return Hlc(millis: maxMillis, counter: next, node: node);
  }

  /// The node id may itself contain dashes, so only the first two are
  /// separators.
  static Hlc? decode(String s) {
    final first = s.indexOf('-');
    if (first < 0) return null;
    final second = s.indexOf('-', first + 1);
    if (second < 0) return null;

    final millis = int.tryParse(s.substring(0, first), radix: 16);
    final counter = int.tryParse(s.substring(first + 1, second), radix: 16);
    if (millis == null || counter == null) return null;
    return Hlc(millis: millis, counter: counter, node: s.substring(second + 1));
  }

  static Hlc now(String node) =>
      Hlc(millis: DateTime.now().millisecondsSinceEpoch, node: node);

  static bool isPlausible(String encoded, int now) {
    final hlc = decode(encoded);
    if (hlc == null) return false;
    return hlc.millis <= now + maxClockSkewMs;
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.node == node;

  @override
  int get hashCode => Object.hash(millis, counter, node);

  @override
  String toString() => encoded();
}
