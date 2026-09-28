import 'dart:math';

import 'package:mynote_core/mynote_core.dart';
import 'package:test/test.dart';

void main() {
  group('FractionalIndex', () {
    test('produces a key between two neighbours', () {
      final a = FractionalIndex.between(null, null);
      final c = FractionalIndex.between(a, null);
      final b = FractionalIndex.between(a, c);
      expect(a.compareTo(b) < 0, isTrue, reason: '$a < $b');
      expect(b.compareTo(c) < 0, isTrue, reason: '$b < $c');
    });

    test('can always insert at the very front', () {
      // The case that used to hang: nothing sorts below "0", so a key must
      // never end in the lowest digit.
      var first = FractionalIndex.between(null, null);
      for (var i = 0; i < 300; i++) {
        final next = FractionalIndex.between(null, first);
        expect(next.compareTo(first) < 0, isTrue,
            reason: '$next should sort before $first');
        first = next;
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('can always insert at the very end', () {
      var last = FractionalIndex.between(null, null);
      for (var i = 0; i < 300; i++) {
        final next = FractionalIndex.between(last, null);
        expect(next.compareTo(last) > 0, isTrue);
        last = next;
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('repeated insertion in the same gap stays ordered', () {
      final low = FractionalIndex.between(null, null);
      var upper = FractionalIndex.between(low, null);
      for (var i = 0; i < 300; i++) {
        final mid = FractionalIndex.between(low, upper);
        expect(low.compareTo(mid) < 0, isTrue);
        expect(mid.compareTo(upper) < 0, isTrue);
        upper = mid;
      }
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a generated key never ends in the lowest digit', () {
      var key = FractionalIndex.between(null, null);
      for (var i = 0; i < 300; i++) {
        expect(key[key.length - 1], isNot('0'),
            reason: 'key $key ends in 0 — nothing can sort below it');
        key = FractionalIndex.between(null, key);
      }
    });

    test('keys stay short enough to be practical', () {
      var key = FractionalIndex.between(null, null);
      for (var i = 0; i < 300; i++) {
        key = FractionalIndex.between(null, key);
      }
      expect(key.length < 120, isTrue,
          reason: 'front-insert key grew to ${key.length} characters');
    });

    test('a generated sequence is strictly increasing', () {
      final keys = FractionalIndex.sequence(50);
      expect(keys.length, 50);
      expect(keys, orderedEquals([...keys]..sort()));
      expect(keys.toSet().length, 50);
    });

    test('random interleaved inserts keep a total order', () {
      final keys = FractionalIndex.sequence(10);
      final random = Random(42); // fixed seed: a failure is reproducible
      for (var i = 0; i < 300; i++) {
        final at = random.nextInt(keys.length + 1);
        final before = at - 1 >= 0 ? keys[at - 1] : null;
        final after = at < keys.length ? keys[at] : null;
        keys.insert(at, FractionalIndex.between(before, after));
      }
      expect(keys, orderedEquals([...keys]..sort()),
          reason: 'insertion broke the ordering');
    });

    test('matches the Swift and Kotlin implementations for generated keys', () {
      // All three must agree, or the same note would order differently on a
      // phone and a tablet.
      expect(FractionalIndex.between(null, null), 'V');
      expect(FractionalIndex.between(null, 'V'), 'F');
      expect(FractionalIndex.between('V', null), 'k');
    });
  });
}
