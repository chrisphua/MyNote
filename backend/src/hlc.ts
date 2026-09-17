/**
 * Hybrid Logical Clock.
 *
 * Wall time alone is unusable for a multi-device offline app: two phones with
 * clocks 3 seconds apart would silently reorder each other's edits. An HLC keeps
 * wall time (so ordering stays human-meaningful) but adds a counter that breaks
 * ties and guarantees each device's own edits are strictly increasing, even if
 * its clock jumps backwards.
 *
 * Encoded as a fixed-width, lexicographically sortable string so SQLite can
 * compare it with plain `<`:
 *     0000018f5a2b3c4d-0000-deviceid
 *     |--- millis ---| |ctr| |-node-|
 */
export interface Hlc {
  millis: number;
  counter: number;
  node: string;
}

const MAX_COUNTER = 0xffff;

export function encodeHlc(h: Hlc): string {
  return `${h.millis.toString(16).padStart(16, '0')}-${h.counter
    .toString(16)
    .padStart(4, '0')}-${h.node}`;
}

export function decodeHlc(s: string): Hlc {
  const parts = s.split('-');
  if (parts.length < 3) throw new Error(`malformed hlc: ${s}`);
  const [m, c, ...rest] = parts as [string, string, ...string[]];
  const millis = parseInt(m, 16);
  const counter = parseInt(c, 16);
  if (!Number.isFinite(millis) || !Number.isFinite(counter)) {
    throw new Error(`malformed hlc: ${s}`);
  }
  return { millis, counter, node: rest.join('-') };
}

/** Lexicographic compare; matches the SQLite collation on the encoded form. */
export function compareHlc(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Advance a local clock for a locally-originated event. */
export function tick(local: Hlc, now: number): Hlc {
  if (now > local.millis) return { millis: now, counter: 0, node: local.node };
  const counter = local.counter + 1;
  if (counter > MAX_COUNTER) {
    // Overflow only happens at >65k events in one millisecond; step the clock.
    return { millis: local.millis + 1, counter: 0, node: local.node };
  }
  return { millis: local.millis, counter, node: local.node };
}

/**
 * Merge a remote clock on receive, so our clock never lags behind what we've seen.
 *
 * The counter is carried into millis on overflow, exactly as `tick` does. A
 * peer can legitimately send `counter = ffff`, and letting it increment to
 * 0x10000 would widen the encoded field from four hex digits to five — which
 * silently breaks the fixed-width lexicographic ordering the SQL `>` relies on.
 */
export function receive(local: Hlc, remote: Hlc, now: number): Hlc {
  const maxMillis = Math.max(local.millis, remote.millis, now);

  let counter: number;
  if (maxMillis === local.millis && maxMillis === remote.millis) {
    counter = Math.max(local.counter, remote.counter) + 1;
  } else if (maxMillis === local.millis) {
    counter = local.counter + 1;
  } else if (maxMillis === remote.millis) {
    counter = remote.counter + 1;
  } else {
    counter = 0;
  }

  if (counter > MAX_COUNTER) return { millis: maxMillis + 1, counter: 0, node: local.node };
  return { millis: maxMillis, counter, node: local.node };
}

/**
 * Reject clocks too far in the future. A device with a badly wrong clock could
 * otherwise write an HLC in the year 2400 and permanently win every future
 * conflict on that record.
 */
export const MAX_CLOCK_SKEW_MS = 24 * 60 * 60 * 1000;

export function isPlausible(hlc: string, now: number): boolean {
  try {
    return decodeHlc(hlc).millis <= now + MAX_CLOCK_SKEW_MS;
  } catch {
    return false;
  }
}
