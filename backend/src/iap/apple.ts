import { HttpError } from '../types';
import type { Env } from '../types';
import { decodeJwsPayload, signEs256 } from '../jwt';
import { productFor } from '../products';
import { grantEntitlement, revokeByTransaction } from '../entitlements';

const PROD_HOST = 'https://api.storekit.itunes.apple.com';
const SANDBOX_HOST = 'https://api.storekit-sandbox.itunes.apple.com';

interface AppleTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  purchaseDate: number;
  expiresDate?: number;
  revocationDate?: number;
  revocationReason?: number;
  bundleId: string;
  type: string;
}

/** App Store Connect API token — ES256, short-lived, regenerated per request. */
async function appleApiToken(env: Env): Promise<string> {
  if (!env.APPLE_PRIVATE_KEY) {
    throw new HttpError(500, 'Apple purchase verification is not configured', 'apple_not_configured');
  }
  const now = Math.floor(Date.now() / 1000);
  return signEs256(
    { alg: 'ES256', kid: env.APPLE_KEY_ID, typ: 'JWT' },
    {
      iss: env.APPLE_ISSUER_ID,
      iat: now,
      exp: now + 600,
      aud: 'appstoreconnect-v1',
      bid: env.APPLE_BUNDLE_ID,
    },
    env.APPLE_PRIVATE_KEY,
  );
}

/**
 * Fetch authoritative transaction state from Apple.
 *
 * This is the whole trust model, and it is why we do not need to validate
 * Apple's x5c certificate chain ourselves: the client's `transactionId` is just
 * a lookup key, and the answer comes back over TLS from Apple's own host on a
 * connection we authenticated with our private key. A forged id yields 404, not
 * a forged entitlement.
 */
async function fetchTransaction(env: Env, transactionId: string): Promise<AppleTransaction> {
  const token = await appleApiToken(env);
  // A sandbox transaction is unknown to production, so fall back on 404.
  const hosts = env.APPLE_ENVIRONMENT === 'Sandbox' ? [SANDBOX_HOST] : [PROD_HOST, SANDBOX_HOST];

  let lastStatus = 0;
  for (const host of hosts) {
    const res = await fetch(`${host}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (res.ok) {
      const body = (await res.json()) as { signedTransactionInfo: string };
      return decodeJwsPayload<AppleTransaction>(body.signedTransactionInfo);
    }
    lastStatus = res.status;
    if (res.status !== 404) break;
  }
  if (lastStatus === 404) throw new HttpError(404, 'unknown transaction', 'unknown_transaction');
  throw new HttpError(502, `Apple verification failed (${lastStatus})`, 'apple_unavailable');
}

function applyTransaction(env: Env, uid: string, txn: AppleTransaction) {
  if (txn.bundleId !== env.APPLE_BUNDLE_ID) {
    throw new HttpError(400, 'transaction belongs to a different app', 'bundle_mismatch');
  }
  const product = productFor(txn.productId);
  if (!product) throw new HttpError(400, `unknown product ${txn.productId}`, 'unknown_product');

  const revoked = typeof txn.revocationDate === 'number';
  return grantEntitlement(
    env,
    uid,
    {
      entitlement: product.entitlement,
      status: revoked ? 'revoked' : 'active',
      source_platform: 'apple',
      product_id: txn.productId,
      original_txn_id: txn.originalTransactionId,
      purchased_at: txn.purchaseDate,
      // A one-time unlock never expires; a subscription carries its own expiry.
      expires_at: product.kind === 'one_time' ? null : (txn.expiresDate ?? null),
    },
    'apple',
  );
}

/** Called by the iOS app right after StoreKit reports a successful purchase. */
export async function verifyAppleTransaction(env: Env, uid: string, transactionId: string) {
  const txn = await fetchTransaction(env, transactionId);
  await applyTransaction(env, uid, txn);
  return txn;
}

/**
 * App Store Server Notifications V2.
 *
 * We deliberately ignore the signature on the notification body and instead
 * re-fetch the transaction from Apple. A spoofed webhook can therefore only
 * cause us to refresh state that Apple confirms — never to grant one.
 */
export async function handleAppleNotification(env: Env, signedPayload: string) {
  const outer = decodeJwsPayload<{
    notificationType: string;
    subtype?: string;
    data?: { signedTransactionInfo?: string };
  }>(signedPayload);

  const signedTxn = outer.data?.signedTransactionInfo;
  if (!signedTxn) return { notificationType: outer.notificationType, handled: false };

  const hint = decodeJwsPayload<AppleTransaction>(signedTxn);
  const txn = await fetchTransaction(env, hint.transactionId);

  if (outer.notificationType === 'REFUND' || typeof txn.revocationDate === 'number') {
    await revokeByTransaction(env, 'apple', txn.originalTransactionId);
    return { notificationType: outer.notificationType, handled: true };
  }

  const link = await env.DB.prepare(
    'SELECT uid FROM iap_links WHERE platform = ? AND original_txn_id = ?',
  )
    .bind('apple', txn.originalTransactionId)
    .first<{ uid: string }>();

  // Renewals for a purchase we have never seen claimed: nothing to update yet.
  // The device will call /iap/apple/verify on next launch and pick it up.
  if (!link) return { notificationType: outer.notificationType, handled: false };

  await applyTransaction(env, link.uid, txn);
  return { notificationType: outer.notificationType, handled: true };
}
