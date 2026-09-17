import { HttpError } from './types';
import type { Env } from './types';
import { requireUser } from './auth';
import { ensureUser } from './db';
import { handleSync } from './sync';
import { listEntitlements, logIapEvent, hasEntitlement } from './entitlements';
import { verifyAppleTransaction, handleAppleNotification } from './iap/apple';
import { verifyGooglePurchase, handleGoogleNotification } from './iap/google';
import { deleteAttachment, getAttachment, putAttachment, storageStatus } from './attachments';

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
  'access-control-allow-headers': 'authorization,content-type',
  'access-control-max-age': '86400',
};

function withCors(res: Response): Response {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(CORS)) headers.set(k, v);
  return new Response(res.body, { status: res.status, headers });
}

function errorResponse(err: unknown): Response {
  if (err instanceof HttpError) {
    return Response.json({ error: err.message, code: err.code }, { status: err.status });
  }
  // Never surface an internal message to a client; log it instead.
  console.error('unhandled', err);
  return Response.json({ error: 'internal error', code: 'internal' }, { status: 500 });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method === 'OPTIONS') return withCors(new Response(null, { status: 204 }));

    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';

    try {
      return withCors(await route(req, env, path));
    } catch (err) {
      return withCors(errorResponse(err));
    }
  },
};

async function route(req: Request, env: Env, path: string): Promise<Response> {
  // --- public ---------------------------------------------------------------
  if (path === '/' || path === '/health') {
    return Response.json({ ok: true, service: 'mynote-api' });
  }

  // Store webhooks authenticate by re-reading state from the store itself
  // (see the comments in iap/apple.ts and iap/google.ts), not by a shared key.
  if (path === '/v1/webhooks/apple' && req.method === 'POST') {
    const body = (await req.json().catch(() => null)) as { signedPayload?: string } | null;
    if (!body?.signedPayload) throw new HttpError(400, 'missing signedPayload', 'bad_request');
    await logIapEvent(env, 'apple', null, null, body);
    const result = await handleAppleNotification(env, body.signedPayload);
    return Response.json(result);
  }

  if (path === '/v1/webhooks/google' && req.method === 'POST') {
    // Pub/Sub push carries no identity we can verify cheaply, so this one path
    // is guarded by a secret in the URL that only Google's subscription knows.
    const url = new URL(req.url);
    if (!env.PUBSUB_SHARED_SECRET || url.searchParams.get('key') !== env.PUBSUB_SHARED_SECRET) {
      throw new HttpError(403, 'forbidden', 'forbidden');
    }
    const body = (await req.json().catch(() => null)) as { message?: { data?: string } } | null;
    if (!body?.message?.data) throw new HttpError(400, 'missing message data', 'bad_request');
    const decoded = JSON.parse(atob(body.message.data));
    await logIapEvent(env, 'google', null, null, decoded);
    const result = await handleGoogleNotification(env, decoded);
    return Response.json(result);
  }

  // --- authenticated --------------------------------------------------------
  const user = await requireUser(req, env);
  await ensureUser(env, user.uid, user.email, user.name);

  if (path === '/v1/me' && req.method === 'GET') {
    return Response.json({
      uid: user.uid,
      email: user.email,
      name: user.name,
      entitlements: await listEntitlements(env, user.uid),
    });
  }

  if (path === '/v1/entitlements' && req.method === 'GET') {
    return Response.json({ entitlements: await listEntitlements(env, user.uid) });
  }

  if (path === '/v1/sync' && req.method === 'POST') {
    // Sync is the paid feature. Local editing never touches this endpoint, so a
    // free user is fully functional offline and only sees this on opt-in.
    if (!(await hasEntitlement(env, user.uid, 'cloud_sync'))) {
      throw new HttpError(402, 'MyNote Sync subscription required', 'payment_required');
    }
    return Response.json(await handleSync(req, env, user));
  }

  if (path === '/v1/iap/apple/verify' && req.method === 'POST') {
    const body = (await req.json().catch(() => null)) as { transactionId?: string } | null;
    if (!body?.transactionId) throw new HttpError(400, 'missing transactionId', 'bad_request');
    await verifyAppleTransaction(env, user.uid, body.transactionId);
    return Response.json({ entitlements: await listEntitlements(env, user.uid) });
  }

  if (path === '/v1/iap/google/verify' && req.method === 'POST') {
    const body = (await req.json().catch(() => null)) as
      | { productId?: string; purchaseToken?: string }
      | null;
    if (!body?.productId || !body?.purchaseToken) {
      throw new HttpError(400, 'missing productId or purchaseToken', 'bad_request');
    }
    await verifyGooglePurchase(env, user.uid, body.productId, body.purchaseToken);
    return Response.json({ entitlements: await listEntitlements(env, user.uid) });
  }

  if (path === '/v1/storage' && req.method === 'GET') {
    return storageStatus(env, user);
  }

  const attachment = /^\/v1\/attachments\/([^/]+)$/.exec(path);
  if (attachment) {
    const id = attachment[1]!;
    if (req.method === 'PUT') return putAttachment(req, env, user, id);
    if (req.method === 'GET') return getAttachment(env, user, id);
    if (req.method === 'DELETE') return deleteAttachment(env, user, id);
    throw new HttpError(405, 'method not allowed', 'method_not_allowed');
  }

  throw new HttpError(404, 'not found', 'not_found');
}
