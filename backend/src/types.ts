export interface Env {
  DB: D1Database;
  ATTACHMENTS: R2Bucket;

  FIREBASE_PROJECT_ID: string;
  APPLE_BUNDLE_ID: string;
  APPLE_ISSUER_ID: string;
  APPLE_KEY_ID: string;
  APPLE_ENVIRONMENT: string;
  GOOGLE_PACKAGE_NAME: string;
  GOOGLE_SA_EMAIL: string;
  FREE_STORAGE_BYTES: string;
  PAID_STORAGE_BYTES: string;

  APPLE_PRIVATE_KEY?: string;
  GOOGLE_SA_PRIVATE_KEY?: string;
  PUBSUB_SHARED_SECRET?: string;
}

/** The four entity kinds that participate in sync. */
export const ENTITIES = ['note', 'block', 'theme', 'attachment'] as const;
export type Entity = (typeof ENTITIES)[number];

/**
 * One change to one record. The client sends these on push and receives them
 * on pull. `hlc` is the authority for conflict resolution; `serverSeq` is only
 * ever assigned by the server and is what the pull cursor walks.
 */
export interface Change {
  entity: Entity;
  id: string;
  hlc: string;
  deleted: boolean;
  serverSeq?: number;
  fields: Record<string, unknown>;
}

export interface SyncRequest {
  cursor: number;
  changes: Change[];
  limit?: number;
}

export interface SyncResponse {
  cursor: number;
  changes: Change[];
  hasMore: boolean;
  serverTime: number;
  /** Ids the server rejected, with a reason — the client should not retry these. */
  rejected: Array<{ entity: Entity; id: string; reason: string }>;
}

export type EntitlementId = 'theme_pro' | 'cloud_sync';

export interface EntitlementRow {
  uid: string;
  entitlement: EntitlementId;
  status: 'active' | 'expired' | 'grace' | 'revoked';
  source_platform: 'apple' | 'google';
  product_id: string;
  original_txn_id: string;
  purchased_at: number;
  expires_at: number | null;
  updated_at: number;
}

export class HttpError extends Error {
  constructor(readonly status: number, message: string, readonly code = 'error') {
    super(message);
  }
}
