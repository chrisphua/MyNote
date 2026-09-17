import type { Change, Entity, Env } from './types';
import { TABLES } from './schema';

/**
 * Allocate `count` sequence numbers for a user and return the first one.
 *
 * D1 runs one statement at a time against a single SQLite instance, and a user's
 * devices rarely push concurrently, so an UPDATE...RETURNING is enough to keep
 * this monotonic without a heavier lock.
 */
export async function allocateSeq(env: Env, uid: string, count: number): Promise<number> {
  if (count <= 0) {
    const row = await env.DB.prepare('SELECT seq FROM counters WHERE uid = ?').bind(uid).first<{ seq: number }>();
    return (row?.seq ?? 0) + 1;
  }
  const row = await env.DB.prepare(
    `INSERT INTO counters (uid, seq) VALUES (?1, ?2)
     ON CONFLICT(uid) DO UPDATE SET seq = seq + ?2
     RETURNING seq`,
  )
    .bind(uid, count)
    .first<{ seq: number }>();
  const end = row?.seq ?? count;
  return end - count + 1;
}

export async function ensureUser(env: Env, uid: string, email: string | null, name: string | null) {
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO users (uid, email, display_name, created_at, last_seen_at)
     VALUES (?1, ?2, ?3, ?4, ?4)
     ON CONFLICT(uid) DO UPDATE SET
       last_seen_at = ?4,
       email        = COALESCE(?2, users.email),
       display_name = COALESCE(?3, users.display_name)`,
  )
    .bind(uid, email, name, now)
    .run();
}

/** Current hlc for a set of ids, so push can decide who wins without a read per row. */
export async function existingHlcs(
  env: Env,
  uid: string,
  entity: Entity,
  ids: string[],
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  const spec = TABLES[entity];
  // Chunked to stay well under SQLite's variable limit.
  for (let i = 0; i < ids.length; i += 100) {
    const chunk = ids.slice(i, i + 100);
    const placeholders = chunk.map(() => '?').join(',');
    const rs = await env.DB.prepare(
      `SELECT id, hlc FROM ${spec.table} WHERE uid = ? AND id IN (${placeholders})`,
    )
      .bind(uid, ...chunk)
      .all<{ id: string; hlc: string }>();
    for (const r of rs.results ?? []) out.set(r.id, r.hlc);
  }
  return out;
}

/** Build the upsert for one change. Server-owned columns are never taken from the client. */
export function upsertStatement(
  env: Env,
  uid: string,
  change: Change,
  seq: number,
): D1PreparedStatement {
  const spec = TABLES[change.entity];
  if (change.deleted) return tombstoneStatement(env, uid, change, seq);
  const cols = ['id', 'uid', ...spec.fields, 'hlc', 'server_seq', 'deleted'];
  const values: unknown[] = [
    change.id,
    uid,
    ...spec.fields.map((f) => normalize(change.fields[f])),
    change.hlc,
    seq,
    change.deleted ? 1 : 0,
  ];
  const placeholders = cols.map((_, i) => `?${i + 1}`).join(', ');
  // Last-write-wins: only overwrite when the incoming clock is strictly newer.
  // Doing the check in SQL closes the race between our read and our write.
  const updates = [...spec.fields, 'hlc', 'server_seq', 'deleted']
    .map((c) => `${c} = excluded.${c}`)
    .join(', ');

  return env.DB.prepare(
    `INSERT INTO ${spec.table} (${cols.join(', ')}) VALUES (${placeholders})
     ON CONFLICT(uid, id) DO UPDATE SET ${updates}
     WHERE excluded.hlc > ${spec.table}.hlc`,
  ).bind(...values);
}

/**
 * Mark a record deleted.
 *
 * Unlike the upsert this leaves the field columns alone on an existing row, so
 * the content survives for restore-from-trash and for the retention job. It is
 * never sent back to a client (see `pullChanges`).
 */
function tombstoneStatement(
  env: Env,
  uid: string,
  change: Change,
  seq: number,
): D1PreparedStatement {
  const spec = TABLES[change.entity];
  const cols = ['id', 'uid', ...spec.fields, 'hlc', 'server_seq', 'deleted'];
  const values: unknown[] = [
    change.id,
    uid,
    ...spec.fields.map((f) => spec.tombstone[f] ?? null),
    change.hlc,
    seq,
    1,
  ];
  const placeholders = cols.map((_, i) => `?${i + 1}`).join(', ');

  return env.DB.prepare(
    `INSERT INTO ${spec.table} (${cols.join(', ')}) VALUES (${placeholders})
     ON CONFLICT(uid, id) DO UPDATE SET
       hlc = excluded.hlc, server_seq = excluded.server_seq, deleted = 1
     WHERE excluded.hlc > ${spec.table}.hlc`,
  ).bind(...values);
}

function normalize(v: unknown): string | number | null {
  if (v === undefined || v === null) return null;
  if (typeof v === 'number' || typeof v === 'string') return v;
  if (typeof v === 'boolean') return v ? 1 : 0;
  return JSON.stringify(v);
}

/**
 * Pull every change past `cursor` in one pass.
 *
 * All four tables share the user's single sequence space, so a UNION ALL ordered
 * by server_seq gives a correct global ordering and the cursor stays one integer.
 */
export async function pullChanges(
  env: Env,
  uid: string,
  cursor: number,
  limit: number,
): Promise<Change[]> {
  const selects = (Object.keys(TABLES) as Entity[]).map((entity) => {
    const spec = TABLES[entity];
    const payload = spec.fields.map((f) => `'${f}', ${f}`).join(', ');
    return `SELECT '${entity}' AS entity, id, hlc, server_seq, deleted,
                   json_object(${payload}) AS fields
            FROM ${spec.table} WHERE uid = ?1 AND server_seq > ?2`;
  });

  const rs = await env.DB.prepare(
    `${selects.join(' UNION ALL ')} ORDER BY server_seq ASC LIMIT ?3`,
  )
    .bind(uid, cursor, limit)
    .all<{
      entity: Entity;
      id: string;
      hlc: string;
      server_seq: number;
      deleted: number;
      fields: string;
    }>();

  return (rs.results ?? []).map((r) => ({
    entity: r.entity,
    id: r.id,
    hlc: r.hlc,
    serverSeq: r.server_seq,
    deleted: r.deleted === 1,
    // A tombstone carries no field values; sending them back would leak the
    // content of a note the user deleted.
    fields: r.deleted === 1 ? {} : (JSON.parse(r.fields) as Record<string, unknown>),
  }));
}

export async function currentSeq(env: Env, uid: string): Promise<number> {
  const row = await env.DB.prepare('SELECT seq FROM counters WHERE uid = ?').bind(uid).first<{ seq: number }>();
  return row?.seq ?? 0;
}
