import type { EntitlementId } from './types';

/**
 * The single source of truth for what a purchase unlocks.
 *
 * Product ids are deliberately identical on both stores, so the same row here
 * serves an Apple and a Google purchase and the mapping can never drift.
 * Prices live in App Store Connect / Play Console; this file only maps sku ->
 * entitlement, which is what the server has to be right about.
 */
export interface Product {
  id: string;
  entitlement: EntitlementId;
  kind: 'one_time' | 'subscription';
}

export const PRODUCTS: Record<string, Product> = {
  'io.mynote.themes.lifetime': { id: 'io.mynote.themes.lifetime', entitlement: 'theme_pro', kind: 'one_time' },
  'io.mynote.sync.monthly':    { id: 'io.mynote.sync.monthly',    entitlement: 'cloud_sync', kind: 'subscription' },
  'io.mynote.sync.yearly':     { id: 'io.mynote.sync.yearly',     entitlement: 'cloud_sync', kind: 'subscription' },
};

export function productFor(sku: string): Product | null {
  return PRODUCTS[sku] ?? null;
}

/** Keep serving a lapsed subscription briefly, so a failed card renewal is not an instant lockout. */
export const GRACE_PERIOD_MS = 3 * 24 * 60 * 60 * 1000;
