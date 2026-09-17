import { HttpError } from './types';
import type { Env } from './types';
import { LIMITS } from './schema';
import { hasEntitlement } from './entitlements';
import type { AuthedUser } from './auth';

/**
 * R2 is the reason this app can offer cloud storage at a sane price: unlike S3
 * it charges nothing for egress, so a user re-downloading their own images on a
 * new device costs us storage only.
 */
function keyFor(uid: string, id: string): string {
  return `u/${uid}/${id}`;
}

function assertId(id: string): void {
  // Ids go straight into an object key, so anything path-like is rejected.
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) {
    throw new HttpError(400, 'invalid attachment id', 'bad_id');
  }
}

async function quotaFor(env: Env, uid: string): Promise<number> {
  const paid = await hasEntitlement(env, uid, 'cloud_sync');
  return Number(paid ? env.PAID_STORAGE_BYTES : env.FREE_STORAGE_BYTES);
}

export async function putAttachment(
  req: Request,
  env: Env,
  user: AuthedUser,
  id: string,
): Promise<Response> {
  assertId(id);

  const declared = Number(req.headers.get('content-length') ?? '0');
  if (!Number.isFinite(declared) || declared <= 0) {
    throw new HttpError(411, 'content-length required', 'length_required');
  }
  if (declared > LIMITS.maxAttachmentBytes) {
    throw new HttpError(413, 'attachment too large', 'too_large');
  }

  const quota = await quotaFor(env, user.uid);
  if (quota === 0) {
    throw new HttpError(402, 'Cloud storage requires a MyNote Sync subscription', 'payment_required');
  }

  const row = await env.DB.prepare('SELECT storage_used FROM users WHERE uid = ?')
    .bind(user.uid)
    .first<{ storage_used: number }>();
  const used = row?.storage_used ?? 0;

  // Replacing an existing object frees its bytes, so count only the delta.
  const existing = await env.ATTACHMENTS.head(keyFor(user.uid, id));
  const delta = declared - (existing?.size ?? 0);
  if (used + delta > quota) {
    throw new HttpError(
      507,
      `Storage full: ${Math.round(quota / 1024 / 1024)} MB limit reached`,
      'quota_exceeded',
    );
  }

  const object = await env.ATTACHMENTS.put(keyFor(user.uid, id), req.body, {
    httpMetadata: { contentType: req.headers.get('content-type') ?? 'application/octet-stream' },
  });
  if (!object) throw new HttpError(500, 'upload failed', 'upload_failed');

  // Trust R2's byte count over the client's content-length header.
  const trueDelta = object.size - (existing?.size ?? 0);
  await env.DB.prepare('UPDATE users SET storage_used = MAX(0, storage_used + ?) WHERE uid = ?')
    .bind(trueDelta, user.uid)
    .run();

  return Response.json({ id, size: object.size, etag: object.httpEtag });
}

export async function getAttachment(env: Env, user: AuthedUser, id: string): Promise<Response> {
  assertId(id);
  const object = await env.ATTACHMENTS.get(keyFor(user.uid, id));
  if (!object) throw new HttpError(404, 'attachment not found', 'not_found');

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set('etag', object.httpEtag);
  // Attachment bytes are immutable once written, so let the device cache hard.
  headers.set('cache-control', 'private, max-age=31536000, immutable');
  return new Response(object.body, { headers });
}

export async function deleteAttachment(env: Env, user: AuthedUser, id: string): Promise<Response> {
  assertId(id);
  const key = keyFor(user.uid, id);
  const existing = await env.ATTACHMENTS.head(key);
  if (existing) {
    await env.ATTACHMENTS.delete(key);
    await env.DB.prepare('UPDATE users SET storage_used = MAX(0, storage_used - ?) WHERE uid = ?')
      .bind(existing.size, user.uid)
      .run();
  }
  return Response.json({ id, deleted: true });
}

export async function storageStatus(env: Env, user: AuthedUser): Promise<Response> {
  const row = await env.DB.prepare('SELECT storage_used FROM users WHERE uid = ?')
    .bind(user.uid)
    .first<{ storage_used: number }>();
  const quota = await quotaFor(env, user.uid);
  return Response.json({ used: row?.storage_used ?? 0, quota });
}
