import { describe, expect, it } from 'vitest';
import { compareHlc, decodeHlc, encodeHlc, isPlausible, receive, tick } from '../src/hlc';

describe('hlc', () => {
  /**
   * Shared vectors.
   *
   * The identical pairs are asserted in `HlcTest.kt` and
   * `HybridLogicalClockTests.swift`. These three encodings must agree byte for
   * byte — the server compares clocks with a plain SQL `>` — and these vectors
   * are the only thing that catches a drift.
   */
  it('encodes to the cross-platform format', () => {
    expect(encodeHlc({ millis: 0x18f5a2b3c4d, counter: 7, node: 'deviceA' }))
      .toBe('0000018f5a2b3c4d-0007-deviceA');
    expect(encodeHlc({ millis: 0, counter: 0, node: 'a' }))
      .toBe('0000000000000000-0000-a');
    expect(encodeHlc({ millis: 1000, counter: 0xffff, node: 'node-with-dashes' }))
      .toBe('00000000000003e8-ffff-node-with-dashes');
  });

  it('decodes a node id containing dashes', () => {
    expect(decodeHlc('000000000000007b-0004-abc-def-ghi').node).toBe('abc-def-ghi');
  });

  it('round-trips through encode/decode', () => {
    const h = { millis: 1_700_000_000_000, counter: 7, node: 'deviceA' };
    expect(decodeHlc(encodeHlc(h))).toEqual(h);
  });

  it('sorts lexicographically in time order', () => {
    const early = encodeHlc({ millis: 1_700_000_000_000, counter: 0, node: 'a' });
    const later = encodeHlc({ millis: 1_700_000_000_001, counter: 0, node: 'a' });
    expect(compareHlc(early, later)).toBe(-1);
    expect([later, early].sort()).toEqual([early, later]);
  });

  it('breaks ties within the same millisecond by counter', () => {
    const first = encodeHlc({ millis: 100, counter: 0, node: 'a' });
    const second = encodeHlc({ millis: 100, counter: 1, node: 'a' });
    expect(first < second).toBe(true);
  });

  it('keeps advancing when the device clock goes backwards', () => {
    // A phone that resyncs NTP can jump backwards; our own edits must still
    // be strictly increasing or we would lose the newer one.
    let clock = { millis: 1000, counter: 0, node: 'a' };
    const before = encodeHlc(clock);
    clock = tick(clock, 500);
    expect(encodeHlc(clock) > before).toBe(true);
  });

  it('never lags behind a clock it has already seen', () => {
    const local = { millis: 1000, counter: 0, node: 'a' };
    const remote = { millis: 5000, counter: 3, node: 'b' };
    const merged = receive(local, remote, 1001);
    expect(merged.millis).toBe(5000);
    expect(encodeHlc(merged) > encodeHlc(remote)).toBe(true);
  });

  it('carries the counter into millis rather than widening the field', () => {
    // A peer can legitimately send counter = ffff. Incrementing past it would
    // encode five hex digits and break the fixed-width ordering the SQL `>`
    // depends on, making every later comparison wrong.
    const local = { millis: 1000, counter: 0xffff, node: 'a' };
    const remote = { millis: 1000, counter: 0xffff, node: 'b' };
    const merged = receive(local, remote, 1000);

    expect(merged.counter).toBeLessThanOrEqual(0xffff);
    expect(encodeHlc(merged).split('-')[1]).toHaveLength(4);
    expect(encodeHlc(merged) > encodeHlc(local)).toBe(true);
  });

  it('keeps tick within the counter field too', () => {
    const saturated = { millis: 1000, counter: 0xffff, node: 'a' };
    const next = tick(saturated, 1000);
    expect(next.millis).toBe(1001);
    expect(next.counter).toBe(0);
    expect(encodeHlc(next) > encodeHlc(saturated)).toBe(true);
  });

  it('rejects a clock implausibly far in the future', () => {
    const now = Date.now();
    const sane = encodeHlc({ millis: now, counter: 0, node: 'a' });
    const bogus = encodeHlc({ millis: now + 90 * 24 * 3600 * 1000, counter: 0, node: 'a' });
    expect(isPlausible(sane, now)).toBe(true);
    expect(isPlausible(bogus, now)).toBe(false);
    expect(isPlausible('not-an-hlc', now)).toBe(false);
  });
});
