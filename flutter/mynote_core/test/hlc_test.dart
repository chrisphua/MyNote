import 'package:mynote_core/mynote_core.dart';
import 'package:test/test.dart';

void main() {
  group('Hlc', () {
    /// Shared vectors.
    ///
    /// The same pairs are asserted in Kotlin's `HlcTest` and Swift's
    /// `HybridLogicalClockTests`. If any implementation drifts, conflict
    /// resolution silently picks the wrong winner, so this is the guard.
    test('encoding matches the cross-platform format', () {
      expect(
        const Hlc(millis: 0x18f5a2b3c4d, counter: 7, node: 'deviceA').encoded(),
        '0000018f5a2b3c4d-0007-deviceA',
      );
      expect(const Hlc(millis: 0, counter: 0, node: 'a').encoded(),
          '0000000000000000-0000-a');
      expect(
        const Hlc(millis: 1000, counter: 0xffff, node: 'node-with-dashes').encoded(),
        '00000000000003e8-ffff-node-with-dashes',
      );
    });

    test('round-trips through decode', () {
      const hlc = Hlc(millis: 1700000000000, counter: 7, node: 'deviceA');
      expect(Hlc.decode(hlc.encoded()), hlc);
    });

    test('node ids containing dashes survive decoding', () {
      const hlc = Hlc(millis: 123, counter: 4, node: 'abc-def-ghi');
      expect(Hlc.decode(hlc.encoded())?.node, 'abc-def-ghi');
    });

    test('sorts lexicographically in time order', () {
      final early = const Hlc(millis: 1700000000000, node: 'a').encoded();
      final later = const Hlc(millis: 1700000000001, node: 'a').encoded();
      expect(early.compareTo(later) < 0, isTrue);
    });

    test('breaks ties within a millisecond by counter', () {
      expect(
        const Hlc(millis: 100, node: 'a').encoded().compareTo(
            const Hlc(millis: 100, counter: 1, node: 'a').encoded()) < 0,
        isTrue,
      );
    });

    test('keeps advancing when the device clock goes backwards', () {
      // A phone that resyncs NTP can jump backwards; our own edits must still
      // be strictly increasing or the newer one would lose.
      const start = Hlc(millis: 1000, node: 'a');
      expect(start.tick(500).encoded().compareTo(start.encoded()) > 0, isTrue);
    });

    test('steps the clock rather than wrapping the counter', () {
      const saturated = Hlc(millis: 1000, counter: Hlc.maxCounter, node: 'a');
      final next = saturated.tick(1000);
      expect(next.millis, 1001);
      expect(next.counter, 0);
      expect(next.encoded().compareTo(saturated.encoded()) > 0, isTrue);
    });

    test('never lags behind a clock it has seen', () {
      const local = Hlc(millis: 1000, node: 'a');
      const remote = Hlc(millis: 5000, counter: 3, node: 'b');
      final merged = local.observe(remote, 1001);
      expect(merged.millis, 5000);
      expect(merged.encoded().compareTo(remote.encoded()) > 0, isTrue);
    });

    test('rejects a clock implausibly far in the future', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(Hlc.isPlausible(Hlc(millis: now, node: 'a').encoded(), now), isTrue);
      expect(
        Hlc.isPlausible(
            Hlc(millis: now + 90 * 24 * 3600 * 1000, node: 'a').encoded(), now),
        isFalse,
      );
      expect(Hlc.isPlausible('not-an-hlc', now), isFalse);
      expect(Hlc.decode('garbage'), isNull);
    });

    test('500 successive stamps are strictly increasing', () {
      var clock = const Hlc(millis: 1000, node: 'a');
      var previous = '';
      for (var i = 0; i < 500; i++) {
        clock = clock.tick(1000); // frozen clock: worst case for monotonicity
        final encoded = clock.encoded();
        expect(encoded.compareTo(previous) > 0, isTrue,
            reason: '$encoded not greater than $previous');
        previous = encoded;
      }
    });

    test('merge carries the counter into millis rather than widening the field', () {
      // A peer can legitimately send counter = ffff. Incrementing past it would
      // encode five hex digits and break the fixed-width ordering every
      // comparison depends on.
      const local = Hlc(millis: 1000, counter: Hlc.maxCounter, node: 'a');
      const remote = Hlc(millis: 1000, counter: Hlc.maxCounter, node: 'b');
      final merged = local.observe(remote, 1000);

      expect(merged.counter <= Hlc.maxCounter, isTrue);
      expect(merged.encoded().split('-')[1].length, 4);
      expect(merged.encoded().compareTo(local.encoded()) > 0, isTrue);
    });
  });
}
