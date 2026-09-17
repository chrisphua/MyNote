import { env } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import { grantEntitlement, hasEntitlement, listEntitlements, revokeByTransaction, uidForPurchaseToken } from '../src/entitlements';
import { GRACE_PERIOD_MS } from '../src/products';
import { HttpError } from '../src/types';

const DAY = 24 * 60 * 60 * 1000;

beforeEach(async () => {
  await env.DB.prepare('DELETE FROM entitlements').run();
  await env.DB.prepare('DELETE FROM iap_links').run();
});

describe('entitlements', () => {
  it('grants a lifetime unlock that never expires', async () => {
    await grantEntitlement(env, 'u1', {
      entitlement: 'theme_pro', status: 'active', source_platform: 'apple',
      product_id: 'io.mynote.themes.lifetime', original_txn_id: 'txn-1',
      purchased_at: Date.now(), expires_at: null,
    }, 'apple');

    expect(await hasEntitlement(env, 'u1', 'theme_pro')).toBe(true);
    expect(await hasEntitlement(env, 'u1', 'cloud_sync')).toBe(false);
  });

  it('unlocks on Android what was purchased on iOS, because entitlements key on uid alone', async () => {
    await grantEntitlement(env, 'u1', {
      entitlement: 'cloud_sync', status: 'active', source_platform: 'apple',
      product_id: 'io.mynote.sync.yearly', original_txn_id: 'apple-txn',
      purchased_at: Date.now(), expires_at: Date.now() + 365 * DAY,
    }, 'apple');

    // Same Firebase account, different device and store. Nothing platform-specific
    // is consulted on read, so the Android client sees the entitlement as-is.
    const seen = await listEntitlements(env, 'u1');
    expect(seen).toHaveLength(1);
    expect(seen[0]!.active).toBe(true);
    expect(seen[0]!.platform).toBe('apple');
  });

  it('refuses to attach one purchase to a second account', async () => {
    const row = {
      entitlement: 'cloud_sync' as const, status: 'active' as const,
      source_platform: 'google' as const, product_id: 'io.mynote.sync.monthly',
      original_txn_id: 'shared-order', purchased_at: Date.now(), expires_at: Date.now() + 30 * DAY,
    };
    await grantEntitlement(env, 'u1', row, 'google', 'token-1');

    await expect(grantEntitlement(env, 'u2', row, 'google', 'token-1'))
      .rejects.toBeInstanceOf(HttpError);
    expect(await hasEntitlement(env, 'u2', 'cloud_sync')).toBe(false);
  });

  it('keeps serving a just-lapsed subscription during the billing grace period', async () => {
    await grantEntitlement(env, 'u1', {
      entitlement: 'cloud_sync', status: 'active', source_platform: 'google',
      product_id: 'io.mynote.sync.monthly', original_txn_id: 'o1',
      purchased_at: Date.now() - 31 * DAY, expires_at: Date.now() - 1000,
    }, 'google');

    const [ent] = await listEntitlements(env, 'u1');
    expect(ent!.active).toBe(true);
    expect(ent!.status).toBe('grace');
  });

  it('cuts off once the grace period has also passed', async () => {
    await grantEntitlement(env, 'u1', {
      entitlement: 'cloud_sync', status: 'active', source_platform: 'google',
      product_id: 'io.mynote.sync.monthly', original_txn_id: 'o1',
      purchased_at: Date.now() - 60 * DAY, expires_at: Date.now() - GRACE_PERIOD_MS - 1000,
    }, 'google');

    const [ent] = await listEntitlements(env, 'u1');
    expect(ent!.active).toBe(false);
    expect(ent!.status).toBe('expired');
  });

  it('revokes on refund, even for a lifetime unlock', async () => {
    await grantEntitlement(env, 'u1', {
      entitlement: 'theme_pro', status: 'active', source_platform: 'apple',
      product_id: 'io.mynote.themes.lifetime', original_txn_id: 'txn-9',
      purchased_at: Date.now(), expires_at: null,
    }, 'apple');
    expect(await hasEntitlement(env, 'u1', 'theme_pro')).toBe(true);

    await revokeByTransaction(env, 'apple', 'txn-9');
    expect(await hasEntitlement(env, 'u1', 'theme_pro')).toBe(false);
  });

  it('resolves a Play purchase token back to its owner for webhooks', async () => {
    await grantEntitlement(env, 'u7', {
      entitlement: 'cloud_sync', status: 'active', source_platform: 'google',
      product_id: 'io.mynote.sync.monthly', original_txn_id: 'order-7',
      purchased_at: Date.now(), expires_at: Date.now() + 30 * DAY,
    }, 'google', 'play-token-7');

    expect(await uidForPurchaseToken(env, 'play-token-7')).toBe('u7');
    expect(await uidForPurchaseToken(env, 'unknown-token')).toBeNull();
  });

  it('upgrading from monthly to yearly replaces the row rather than duplicating it', async () => {
    const base = {
      entitlement: 'cloud_sync' as const, status: 'active' as const,
      source_platform: 'apple' as const, purchased_at: Date.now(),
    };
    await grantEntitlement(env, 'u1', {
      ...base, product_id: 'io.mynote.sync.monthly',
      original_txn_id: 't1', expires_at: Date.now() + 30 * DAY,
    }, 'apple');
    await grantEntitlement(env, 'u1', {
      ...base, product_id: 'io.mynote.sync.yearly',
      original_txn_id: 't1', expires_at: Date.now() + 365 * DAY,
    }, 'apple');

    const all = await listEntitlements(env, 'u1');
    expect(all).toHaveLength(1);
    expect(all[0]!.productId).toBe('io.mynote.sync.yearly');
  });
});
