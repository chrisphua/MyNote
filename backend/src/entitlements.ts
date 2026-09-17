import { HttpError } from './types';
import type { EntitlementId, EntitlementRow, Env } from './types';
import { GRACE_PERIOD_MS } from './products';

export interface ResolvedEntitlement {
  entitlement: EntitlementId;
  active: boolean;
  status: string;
  expiresAt: number | null;
  productId: string;
  platform: string;
}

/**
 * Record a verified purchase.
 *
 * `original_txn_id` is bound to one uid the first time we see it, which is what
 * stops a shared receipt from unlocking an unlimited number of accounts.
 */
export async function grantEntitlement(
  env: Env,
  uid: string,
  row: Omit<EntitlementRow, 'uid' | 'updated_at'>,
  platform: 'apple' | 'google',
  purchaseToken: string | null = null,
): Promise<void> {
  const now = Date.now();

  const link = await env.DB.prepare(
    'SELECT uid FROM iap_links WHERE platform = ? AND original_txn_id = ?',
  )
    .bind(platform, row.original_txn_id)
    .first<{ uid: string }>();

  if (link && link.uid !== uid) {
    throw new HttpError(
      409,
      'This purchase is already attached to another MyNote account. Sign in with that account, or contact support to move it.',
      'purchase_already_linked',
    );
  }

  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO iap_links (platform, original_txn_id, uid, purchase_token, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5)
       ON CONFLICT(platform, original_txn_id) DO UPDATE SET
         purchase_token = COALESCE(excluded.purchase_token, iap_links.purchase_token)`,
    ).bind(platform, row.original_txn_id, uid, purchaseToken, now),
    env.DB.prepare(
      `INSERT INTO entitlements
         (uid, entitlement, status, source_platform, product_id, original_txn_id, purchased_at, expires_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
       ON CONFLICT(uid, entitlement) DO UPDATE SET
         status          = excluded.status,
         source_platform = excluded.source_platform,
         product_id      = excluded.product_id,
         original_txn_id = excluded.original_txn_id,
         expires_at      = excluded.expires_at,
         updated_at      = excluded.updated_at
       WHERE excluded.updated_at >= entitlements.updated_at`,
    ).bind(
      uid, row.entitlement, row.status, platform, row.product_id,
      row.original_txn_id, row.purchased_at, row.expires_at, now,
    ),
  ]);
}

/** Every entitlement for a user, with expiry evaluated at read time. */
export async function listEntitlements(env: Env, uid: string): Promise<ResolvedEntitlement[]> {
  const rs = await env.DB.prepare('SELECT * FROM entitlements WHERE uid = ?')
    .bind(uid)
    .all<EntitlementRow>();

  const now = Date.now();
  return (rs.results ?? []).map((r) => {
    let active: boolean;
    let status = r.status;

    if (r.status === 'revoked') {
      active = false;                       // refunded or charged back
    } else if (r.expires_at === null) {
      active = true;                        // lifetime unlock, e.g. themes
    } else if (r.expires_at > now) {
      active = true;
    } else if (r.expires_at + GRACE_PERIOD_MS > now) {
      active = true;                        // billing retry window
      status = 'grace';
    } else {
      active = false;
      status = 'expired';
    }

    return {
      entitlement: r.entitlement,
      active,
      status,
      expiresAt: r.expires_at,
      productId: r.product_id,
      platform: r.source_platform,
    };
  });
}

export async function hasEntitlement(env: Env, uid: string, id: EntitlementId): Promise<boolean> {
  const all = await listEntitlements(env, uid);
  return all.some((e) => e.entitlement === id && e.active);
}

/** Resolve a Play purchase token to the account that claimed it. */
export async function uidForPurchaseToken(env: Env, token: string): Promise<string | null> {
  const row = await env.DB.prepare(
    `SELECT uid FROM iap_links WHERE platform = 'google' AND purchase_token = ?`,
  )
    .bind(token)
    .first<{ uid: string }>();
  return row?.uid ?? null;
}

export async function revokeByTransaction(
  env: Env,
  platform: 'apple' | 'google',
  originalTxnId: string,
): Promise<void> {
  const link = await env.DB.prepare(
    'SELECT uid FROM iap_links WHERE platform = ? AND original_txn_id = ?',
  )
    .bind(platform, originalTxnId)
    .first<{ uid: string }>();
  if (!link) return;

  await env.DB.prepare(
    `UPDATE entitlements SET status = 'revoked', updated_at = ?
     WHERE uid = ? AND original_txn_id = ?`,
  )
    .bind(Date.now(), link.uid, originalTxnId)
    .run();
}

export async function logIapEvent(
  env: Env,
  platform: string,
  notifType: string | null,
  uid: string | null,
  payload: unknown,
): Promise<void> {
  await env.DB.prepare(
    'INSERT INTO iap_events (id, platform, notif_type, uid, payload, received_at) VALUES (?, ?, ?, ?, ?, ?)',
  )
    .bind(crypto.randomUUID(), platform, notifType, uid, JSON.stringify(payload).slice(0, 100_000), Date.now())
    .run();
}
