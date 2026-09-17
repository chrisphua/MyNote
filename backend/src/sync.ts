import { HttpError } from './types';
import type { Change, Entity, Env, SyncRequest, SyncResponse } from './types';
import { ENTITIES } from './types';
import { BLOCK_TYPES, LIMITS, TABLES } from './schema';
import { isPlausible } from './hlc';
import { allocateSeq, currentSeq, existingHlcs, pullChanges, upsertStatement } from './db';
import type { AuthedUser } from './auth';

interface Rejection { entity: Entity; id: string; reason: string }

/**
 * Validate one inbound change.
 *
 * Everything here is a client-supplied value, so this is the trust boundary:
 * past this point the change is treated as safe to write.
 */
function validate(raw: unknown, now: number): Change | Rejection {
  const c = raw as Partial<Change>;
  const entity = c?.entity as Entity;
  const id = typeof c?.id === 'string' ? c.id : '';

  if (!ENTITIES.includes(entity)) return { entity: entity ?? 'note', id, reason: 'unknown_entity' };
  if (!id || id.length > LIMITS.maxIdLength) return { entity, id, reason: 'bad_id' };
  if (typeof c.hlc !== 'string' || !isPlausible(c.hlc, now)) {
    return { entity, id, reason: 'bad_clock' };
  }

  const deleted = c.deleted === true;
  const fields = (c.fields ?? {}) as Record<string, unknown>;

  // A tombstone carries no payload, so there is nothing further to check.
  if (deleted) return { entity, id, hlc: c.hlc, deleted: true, fields: {} };

  const spec = TABLES[entity];
  for (const f of spec.required) {
    const v = fields[f];
    if (v === undefined || v === null || v === '') {
      return { entity, id, reason: `missing_${f}` };
    }
  }

  // Drop unknown keys rather than rejecting, so an older server stays
  // compatible with a newer client that added a field.
  const clean: Record<string, unknown> = {};
  for (const f of spec.fields) if (f in fields) clean[f] = fields[f];

  const sized = (v: unknown, max: number) =>
    typeof v === 'string' && new TextEncoder().encode(v).length > max;

  if (entity === 'note') {
    if (sized(clean.title, LIMITS.maxTitleLength)) return { entity, id, reason: 'title_too_long' };
    if (clean.parent_id === id) return { entity, id, reason: 'self_parent' };
  }
  if (entity === 'block') {
    if (!BLOCK_TYPES.has(String(clean.type))) return { entity, id, reason: 'bad_block_type' };
    if (sized(clean.content, LIMITS.maxBlockContentBytes)) return { entity, id, reason: 'content_too_large' };
    if (!isJson(clean.content)) return { entity, id, reason: 'content_not_json' };
    if (clean.parent_id === id) return { entity, id, reason: 'self_parent' };
  }
  if (entity === 'theme') {
    if (sized(clean.spec, LIMITS.maxThemeSpecBytes)) return { entity, id, reason: 'spec_too_large' };
    if (!isJson(clean.spec)) return { entity, id, reason: 'spec_not_json' };
  }
  if (entity === 'attachment') {
    const size = Number(clean.size);
    if (!Number.isInteger(size) || size < 0 || size > LIMITS.maxAttachmentBytes) {
      return { entity, id, reason: 'bad_size' };
    }
  }
  if (sized(clean.order_key, LIMITS.maxOrderKeyLength)) return { entity, id, reason: 'order_key_too_long' };

  return { entity, id, hlc: c.hlc, deleted: false, fields: clean };
}

function isJson(v: unknown): boolean {
  if (typeof v !== 'string') return false;
  try { JSON.parse(v); return true; } catch { return false; }
}

function isRejection(v: Change | Rejection): v is Rejection {
  return 'reason' in v;
}

export async function handleSync(req: Request, env: Env, user: AuthedUser): Promise<SyncResponse> {
  const body = (await req.json().catch(() => null)) as SyncRequest | null;
  if (!body || typeof body !== 'object') throw new HttpError(400, 'body must be JSON', 'bad_request');

  const cursor = Number.isInteger(body.cursor) && body.cursor >= 0 ? body.cursor : 0;
  const incoming = Array.isArray(body.changes) ? body.changes : [];
  if (incoming.length > LIMITS.maxChangesPerPush) {
    throw new HttpError(
      413,
      `push at most ${LIMITS.maxChangesPerPush} changes per request`,
      'batch_too_large',
    );
  }

  const now = Date.now();
  const accepted: Change[] = [];
  const rejected: Rejection[] = [];
  for (const raw of incoming) {
    const result = validate(raw, now);
    if (isRejection(result)) rejected.push(result);
    else accepted.push(result);
  }

  // Within a single push the client may send several edits to the same record;
  // only the newest can win, so collapse them before touching the database.
  const newestById = new Map<string, Change>();
  for (const c of accepted) {
    const key = `${c.entity}:${c.id}`;
    const prev = newestById.get(key);
    if (!prev || c.hlc > prev.hlc) newestById.set(key, c);
  }

  // Skip writes the server would reject anyway (its copy is already newer).
  // The SQL upsert enforces this too; this pass just avoids burning sequence
  // numbers and D1 row writes on no-ops.
  const toWrite: Change[] = [];
  for (const entity of ENTITIES) {
    const group = [...newestById.values()].filter((c) => c.entity === entity);
    if (group.length === 0) continue;
    const existing = await existingHlcs(env, user.uid, entity, group.map((c) => c.id));
    for (const c of group) {
      const seen = existing.get(c.id);
      if (!seen || c.hlc > seen) toWrite.push(c);
    }
  }

  if (toWrite.length > 0) {
    const first = await allocateSeq(env, user.uid, toWrite.length);
    await env.DB.batch(toWrite.map((c, i) => upsertStatement(env, user.uid, c, first + i)));
  }

  // Pull after push so a device that just wrote sees a consistent view, and so
  // a two-device conflict resolves in one round trip instead of two.
  const limit = Math.min(
    Math.max(Number(body.limit) || LIMITS.defaultPullPageSize, 1),
    LIMITS.maxPullPageSize,
  );
  const changes = await pullChanges(env, user.uid, cursor, limit + 1);
  const hasMore = changes.length > limit;
  const page = hasMore ? changes.slice(0, limit) : changes;

  const nextCursor = page.length > 0 ? page[page.length - 1]!.serverSeq! : await currentSeq(env, user.uid);

  return { cursor: nextCursor, changes: page, hasMore, serverTime: now, rejected };
}
