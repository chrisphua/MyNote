import { HttpError } from '../types';
import type { Env } from '../types';
import { signRs256 } from '../jwt';
import { productFor } from '../products';
import { grantEntitlement, revokeByTransaction, uidForPurchaseToken } from '../entitlements';

const API = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

let tokenCache: { token: string; expiresAt: number } | null = null;

/** Service-account OAuth token, cached until shortly before it expires. */
async function accessToken(env: Env): Promise<string> {
  if (tokenCache && tokenCache.expiresAt > Date.now() + 60_000) return tokenCache.token;
  if (!env.GOOGLE_SA_PRIVATE_KEY) {
    throw new HttpError(500, 'Google purchase verification is not configured', 'google_not_configured');
  }

  const now = Math.floor(Date.now() / 1000);
  const assertion = await signRs256(
    { alg: 'RS256', typ: 'JWT' },
    {
      iss: env.GOOGLE_SA_EMAIL,
      scope: SCOPE,
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    },
    env.GOOGLE_SA_PRIVATE_KEY,
  );

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });
  if (!res.ok) throw new HttpError(502, 'Google token exchange failed', 'google_unavailable');

  const body = (await res.json()) as { access_token: string; expires_in: number };
  tokenCache = { token: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  return body.access_token;
}

async function call(env: Env, path: string, init?: RequestInit): Promise<any> {
  const token = await accessToken(env);
  const res = await fetch(`${API}/${env.GOOGLE_PACKAGE_NAME}${path}`, {
    ...init,
    headers: { ...(init?.headers ?? {}), Authorization: `Bearer ${token}` },
  });
  if (res.status === 404) throw new HttpError(404, 'unknown purchase token', 'unknown_transaction');
  if (!res.ok) throw new HttpError(502, `Google verification failed (${res.status})`, 'google_unavailable');
  return res.status === 204 ? {} : res.json();
}

interface SubscriptionV2 {
  subscriptionState: string;
  latestOrderId?: string;
  startTime?: string;
  lineItems?: Array<{ productId: string; expiryTime?: string }>;
  acknowledgementState?: string;
}

interface ProductPurchase {
  purchaseState: number;      // 0 purchased, 1 cancelled, 2 pending
  orderId?: string;
  productId?: string;
  purchaseTimeMillis?: string;
  acknowledgementState?: number;  // 0 pending, 1 acknowledged
}

const ACTIVE_STATES = new Set([
  'SUBSCRIPTION_STATE_ACTIVE',
  'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
  'SUBSCRIPTION_STATE_CANCELED',  // cancelled but paid through expiryTime
]);

/**
 * Verify a Play purchase token and record the entitlement.
 *
 * Acknowledging is not optional: Google auto-refunds any purchase left
 * unacknowledged for three days, so we do it as soon as the grant succeeds.
 */
export async function verifyGooglePurchase(
  env: Env,
  uid: string,
  sku: string,
  purchaseToken: string,
): Promise<{ entitlement: string; expiresAt: number | null }> {
  const product = productFor(sku);
  if (!product) throw new HttpError(400, `unknown product ${sku}`, 'unknown_product');

  const tok = encodeURIComponent(purchaseToken);

  if (product.kind === 'subscription') {
    const sub = (await call(env, `/purchases/subscriptionsv2/tokens/${tok}`)) as SubscriptionV2;

    const line = sub.lineItems?.find((l) => l.productId === sku) ?? sub.lineItems?.[0];
    if (!line) throw new HttpError(400, 'purchase has no line items', 'bad_purchase');
    if (line.productId !== sku) {
      throw new HttpError(400, 'purchase token is for a different product', 'product_mismatch');
    }

    const active = ACTIVE_STATES.has(sub.subscriptionState);
    const expiresAt = line.expiryTime ? Date.parse(line.expiryTime) : null;
    const orderId = sub.latestOrderId ?? purchaseToken;
    // Play appends "..0", "..1" per renewal; the base is the stable original id.
    const originalTxnId = orderId.split('..')[0]!;

    await grantEntitlement(
      env,
      uid,
      {
        entitlement: product.entitlement,
        status: active ? 'active' : 'expired',
        source_platform: 'google',
        product_id: sku,
        original_txn_id: originalTxnId,
        purchased_at: sub.startTime ? Date.parse(sub.startTime) : Date.now(),
        expires_at: expiresAt,
      },
      'google',
      purchaseToken,
    );

    if (sub.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING') {
      await call(env, `/purchases/subscriptions/${encodeURIComponent(sku)}/tokens/${tok}:acknowledge`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{}',
      });
    }
    return { entitlement: product.entitlement, expiresAt };
  }

  const purchase = (await call(
    env,
    `/purchases/products/${encodeURIComponent(sku)}/tokens/${tok}`,
  )) as ProductPurchase;

  if (purchase.purchaseState !== 0) {
    throw new HttpError(400, 'purchase is not in a completed state', 'purchase_incomplete');
  }

  const originalTxnId = purchase.orderId ?? purchaseToken;
  await grantEntitlement(
    env,
    uid,
    {
      entitlement: product.entitlement,
      status: 'active',
      source_platform: 'google',
      product_id: sku,
      original_txn_id: originalTxnId,
      purchased_at: Number(purchase.purchaseTimeMillis ?? Date.now()),
      expires_at: null,
    },
    'google',
    purchaseToken,
  );

  if (purchase.acknowledgementState === 0) {
    await call(env, `/purchases/products/${encodeURIComponent(sku)}/tokens/${tok}:acknowledge`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
  }
  return { entitlement: product.entitlement, expiresAt: null };
}

/**
 * Play Real-time Developer Notifications, delivered via Pub/Sub push.
 *
 * Same trust model as Apple: the notification only tells us *which* purchase
 * changed, and we re-read the truth from Google's API before acting.
 */
export async function handleGoogleNotification(env: Env, message: unknown) {
  const decoded = message as {
    subscriptionNotification?: { purchaseToken: string; subscriptionId: string; notificationType: number };
    voidedPurchaseNotification?: { purchaseToken: string; orderId?: string };
    oneTimeProductNotification?: { purchaseToken: string; sku: string };
  };

  if (decoded.voidedPurchaseNotification) {
    const { orderId, purchaseToken } = decoded.voidedPurchaseNotification;
    if (orderId) {
      await revokeByTransaction(env, 'google', orderId.split('..')[0]!);
      return { handled: true, kind: 'voided' };
    }
    // Play does not always include an orderId. The token is the handle we keyed
    // the account link on, so fall back to it rather than silently keeping a
    // refunded purchase active.
    const uid = await uidForPurchaseToken(env, purchaseToken);
    if (!uid) return { handled: false, kind: 'voided_unlinked' };
    await env.DB.prepare(
      `UPDATE entitlements SET status = 'revoked', updated_at = ?
       WHERE uid = ? AND original_txn_id IN (
         SELECT original_txn_id FROM iap_links WHERE platform = 'google' AND purchase_token = ?
       )`,
    )
      .bind(Date.now(), uid, purchaseToken)
      .run();
    return { handled: true, kind: 'voided' };
  }

  const sub = decoded.subscriptionNotification;
  const one = decoded.oneTimeProductNotification;
  const token = sub?.purchaseToken ?? one?.purchaseToken;
  const sku = sub?.subscriptionId ?? one?.sku;
  if (!token || !sku) return { handled: false, kind: 'ignored' };

  // The token is the only stable handle Play gives us, so that is what we keyed
  // the account link on at purchase time.
  const uid = await uidForPurchaseToken(env, token);

  // Unclaimed purchase: the device will verify it on next launch.
  if (!uid) return { handled: false, kind: 'unlinked' };

  await verifyGooglePurchase(env, uid, sku, token);
  return { handled: true, kind: 'refreshed' };
}
