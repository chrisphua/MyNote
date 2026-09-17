import { env } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import { handleSync } from '../src/sync';
import { encodeHlc } from '../src/hlc';
import type { Change, SyncResponse } from '../src/types';

const USER = { uid: 'user-1', email: 'a@example.com', name: 'A' };
const OTHER = { uid: 'user-2', email: 'b@example.com', name: 'B' };

function hlc(millis: number, node = 'devA', counter = 0) {
  return encodeHlc({ millis, counter, node });
}

function block(id: string, text: string, at: number, node = 'devA'): Change {
  return {
    entity: 'block',
    id,
    hlc: hlc(at, node),
    deleted: false,
    fields: {
      note_id: 'note-1',
      order_key: 'V',
      type: 'paragraph',
      content: JSON.stringify({ text }),
    },
  };
}

async function sync(user: typeof USER, cursor: number, changes: Change[]): Promise<SyncResponse> {
  const req = new Request('https://api.test/v1/sync', {
    method: 'POST',
    body: JSON.stringify({ cursor, changes }),
  });
  return handleSync(req, env, user);
}

beforeEach(async () => {
  for (const t of ['notes', 'blocks', 'themes', 'attachments', 'counters']) {
    await env.DB.prepare(`DELETE FROM ${t}`).run();
  }
});

describe('sync', () => {
  it('pushes a change and reads it back on the next pull', async () => {
    const pushed = await sync(USER, 0, [block('b1', 'hello', 1000)]);
    expect(pushed.rejected).toHaveLength(0);
    expect(pushed.changes).toHaveLength(1);
    expect(pushed.changes[0]!.id).toBe('b1');
    expect(JSON.parse(pushed.changes[0]!.fields.content as string).text).toBe('hello');

    // A second device starting from zero sees the same state.
    const fresh = await sync(USER, 0, []);
    expect(fresh.changes).toHaveLength(1);
  });

  it('advances the cursor so a device does not re-download its own writes', async () => {
    const first = await sync(USER, 0, [block('b1', 'one', 1000)]);
    const second = await sync(USER, first.cursor, []);
    expect(second.changes).toHaveLength(0);
    expect(second.cursor).toBe(first.cursor);
  });

  it('resolves a two-device conflict in favour of the newer clock', async () => {
    await sync(USER, 0, [block('b1', 'from-phone', 2000, 'phone')]);
    // The tablet was offline and edited the same block earlier.
    const late = await sync(USER, 0, [block('b1', 'from-tablet', 1000, 'tablet')]);

    const winner = late.changes.find((c) => c.id === 'b1')!;
    expect(JSON.parse(winner.fields.content as string).text).toBe('from-phone');
  });

  it('lets a newer edit overwrite an older one', async () => {
    await sync(USER, 0, [block('b1', 'old', 1000)]);
    const after = await sync(USER, 0, [block('b1', 'new', 3000)]);
    const row = after.changes.find((c) => c.id === 'b1')!;
    expect(JSON.parse(row.fields.content as string).text).toBe('new');
  });

  it('collapses several edits to one record within a single push', async () => {
    const res = await sync(USER, 0, [
      block('b1', 'v1', 1000),
      block('b1', 'v2', 2000),
      block('b1', 'v3', 1500),
    ]);
    expect(res.changes).toHaveLength(1);
    expect(JSON.parse(res.changes[0]!.fields.content as string).text).toBe('v2');
  });

  it('propagates deletes as tombstones without leaking content', async () => {
    await sync(USER, 0, [block('b1', 'secret', 1000)]);
    await sync(USER, 0, [{ entity: 'block', id: 'b1', hlc: hlc(2000), deleted: true, fields: {} }]);

    const fresh = await sync(USER, 0, []);
    const tomb = fresh.changes.find((c) => c.id === 'b1')!;
    expect(tomb.deleted).toBe(true);
    expect(tomb.fields).toEqual({});
    expect(JSON.stringify(tomb)).not.toContain('secret');
  });

  it('never returns one user\'s data to another', async () => {
    await sync(USER, 0, [block('b1', 'private', 1000)]);
    const intruder = await sync(OTHER, 0, []);
    expect(intruder.changes).toHaveLength(0);
  });

  it('refuses to let one user overwrite another user\'s record by id', async () => {
    await sync(USER, 0, [block('b1', 'mine', 1000)]);
    await sync(OTHER, 0, [block('b1', 'hijacked', 9000)]);

    const owner = await sync(USER, 0, []);
    const row = owner.changes.find((c) => c.id === 'b1')!;
    expect(JSON.parse(row.fields.content as string).text).toBe('mine');
  });

  it('rejects malformed changes without dropping the good ones', async () => {
    const res = await sync(USER, 0, [
      block('good', 'fine', 1000),
      { entity: 'block', id: 'bad-type', hlc: hlc(1000), deleted: false,
        fields: { note_id: 'n', order_key: 'V', type: 'nonsense', content: '{}' } },
      { entity: 'block', id: 'bad-json', hlc: hlc(1000), deleted: false,
        fields: { note_id: 'n', order_key: 'V', type: 'paragraph', content: 'not json' } },
      { entity: 'block', id: 'bad-clock', hlc: 'garbage', deleted: false,
        fields: { note_id: 'n', order_key: 'V', type: 'paragraph', content: '{}' } },
      { entity: 'note', id: 'no-order-key', hlc: hlc(1000), deleted: false, fields: { title: 'x' } },
    ] as Change[]);

    expect(res.changes.map((c) => c.id)).toEqual(['good']);
    expect(res.rejected.map((r) => r.reason).sort()).toEqual(
      ['bad_block_type', 'bad_clock', 'content_not_json', 'missing_order_key'],
    );
  });

  it('rejects a clock far enough in the future to poison future writes', async () => {
    const res = await sync(USER, 0, [block('b1', 'time traveller', Date.now() + 40 * 24 * 3600 * 1000)]);
    expect(res.rejected[0]!.reason).toBe('bad_clock');
    expect(res.changes).toHaveLength(0);
  });

  it('pages large pulls and reports hasMore', async () => {
    const many = Array.from({ length: 12 }, (_, i) => block(`b${i}`, `t${i}`, 1000 + i));
    await sync(USER, 0, many);

    const page1 = await sync(USER, 0, []);
    expect(page1.changes).toHaveLength(12);

    const small = await handleSync(
      new Request('https://api.test/v1/sync', {
        method: 'POST',
        body: JSON.stringify({ cursor: 0, changes: [], limit: 5 }),
      }),
      env,
      USER,
    );
    expect(small.changes).toHaveLength(5);
    expect(small.hasMore).toBe(true);

    const rest = await handleSync(
      new Request('https://api.test/v1/sync', {
        method: 'POST',
        body: JSON.stringify({ cursor: small.cursor, changes: [], limit: 50 }),
      }),
      env,
      USER,
    );
    expect(rest.changes).toHaveLength(7);
    expect(rest.hasMore).toBe(false);
  });

  it('syncs notes, themes and attachments through the same cursor', async () => {
    await sync(USER, 0, [
      { entity: 'note', id: 'n1', hlc: hlc(1000), deleted: false,
        fields: { title: 'Trip', order_key: 'V' } },
      { entity: 'theme', id: 't1', hlc: hlc(1001), deleted: false,
        fields: { name: 'Midnight', spec: JSON.stringify({ bg: '#000' }) } },
      { entity: 'attachment', id: 'a1', hlc: hlc(1002), deleted: false,
        fields: { r2_key: 'u/user-1/a1', mime: 'image/png', size: 1234 } },
    ]);

    const all = await sync(USER, 0, []);
    expect(all.changes.map((c) => c.entity).sort()).toEqual(['attachment', 'note', 'theme']);
    // One monotonic cursor across every entity type.
    const seqs = all.changes.map((c) => c.serverSeq!);
    expect([...seqs].sort((a, b) => a - b)).toEqual(seqs);
  });

  it('refuses an oversized batch rather than partially applying it', async () => {
    const huge = Array.from({ length: 501 }, (_, i) => block(`x${i}`, 't', 1000 + i));
    await expect(sync(USER, 0, huge)).rejects.toThrow(/at most 500/);
  });
});

describe('sync — concurrency and isolation', () => {
  it('does not advance the cursor past rows that are not visible yet', async () => {
    // `allocateSeq` bumps the counter before the batch inserts. A device that
    // pulls an empty page in that window must not adopt the counter value, or it
    // would skip the rows being written and never see them again.
    await sync(USER, 0, [block('b1', 'first', 1000)]);
    const settled = await sync(USER, 0, []);

    // Simulate another device reserving sequence numbers without committing.
    await env.DB.prepare(
      `INSERT INTO counters (uid, seq) VALUES (?1, ?2)
       ON CONFLICT(uid) DO UPDATE SET seq = seq + ?2`,
    ).bind(USER.uid, 5).run();

    const empty = await sync(USER, settled.cursor, []);
    expect(empty.changes).toHaveLength(0);
    expect(empty.cursor).toBe(settled.cursor);
  });

  it('lets two accounts use the same record id independently', async () => {
    // Ids are client-generated. A collision across accounts must write both
    // rows, not silently drop whichever arrived second.
    await sync(USER, 0, [block('shared-id', 'mine', 1000)]);
    await sync(OTHER, 0, [block('shared-id', 'theirs', 2000)]);

    const mine = await sync(USER, 0, []);
    const theirs = await sync(OTHER, 0, []);

    expect(JSON.parse(mine.changes[0]!.fields.content as string).text).toBe('mine');
    expect(JSON.parse(theirs.changes[0]!.fields.content as string).text).toBe('theirs');
  });

  it('rejects an order key that nothing could sort below', async () => {
    const bad = (key: string): Change => ({
      entity: 'note', id: `n-${key}`, hlc: hlc(1000), deleted: false,
      fields: { title: 'x', order_key: key },
    });

    const res = await sync(USER, 0, [bad('a0'), bad('a/b'), bad('')]);
    // 'a0' ends in the lowest digit; 'a/b' is outside the alphabet; '' is empty.
    expect(res.rejected.map((r) => r.reason).sort())
      .toEqual(['bad_order_key', 'bad_order_key', 'missing_order_key']);
    expect(res.changes).toHaveLength(0);
  });

  it('accepts the order keys the clients actually generate', async () => {
    const good = (key: string): Change => ({
      entity: 'note', id: `n-${key}`, hlc: hlc(1000), deleted: false,
      fields: { title: 'x', order_key: key },
    });
    const res = await sync(USER, 0, [good('V'), good('a1'), good('0V'), good('zzZ9')]);
    expect(res.rejected).toHaveLength(0);
    expect(res.changes).toHaveLength(4);
  });
});
