import { describe, expect, it } from 'vitest';
import { compareHlc, decodeHlc, encodeHlc, isPlausible, receive, tick } from '../src/hlc';

describe('hlc', () => {
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

  it('rejects a clock implausibly far in the future', () => {
    const now = Date.now();
    const sane = encodeHlc({ millis: now, counter: 0, node: 'a' });
    const bogus = encodeHlc({ millis: now + 90 * 24 * 3600 * 1000, counter: 0, node: 'a' });
    expect(isPlausible(sane, now)).toBe(true);
    expect(isPlausible(bogus, now)).toBe(false);
    expect(isPlausible('not-an-hlc', now)).toBe(false);
  });
});
