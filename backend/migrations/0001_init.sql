-- MyNote D1 schema (SQLite).
-- Design notes:
--  * Every syncable row carries `hlc` (hybrid logical clock) for conflict resolution
--    and `server_seq` for cursor-based pull. `server_seq` is allocated from `counters`
--    inside the same atomic batch as the write, so it is strictly monotonic per user.
--  * Deletes are tombstones (`deleted = 1`) so offline devices learn about them.
--  * Nothing is ever hard-deleted except by the retention job in `scripts/gc.sql`.

CREATE TABLE IF NOT EXISTS users (
  uid              TEXT PRIMARY KEY,
  email            TEXT,
  display_name     TEXT,
  created_at       INTEGER NOT NULL,
  last_seen_at     INTEGER NOT NULL,
  storage_used     INTEGER NOT NULL DEFAULT 0,   -- bytes in R2
  deleted_at       INTEGER
);

-- Monotonic sequence allocator, one row per user.
CREATE TABLE IF NOT EXISTS counters (
  uid   TEXT PRIMARY KEY,
  seq   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS notes (
  id           TEXT NOT NULL,
  uid          TEXT NOT NULL,
  title        TEXT NOT NULL DEFAULT '',
  icon         TEXT,
  parent_id    TEXT,                 -- notes nest, like Notion pages
  order_key    TEXT NOT NULL,        -- fractional index among siblings
  hlc          TEXT NOT NULL,
  server_seq   INTEGER NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0,
  -- Keyed per user, not globally: two accounts generating the same id must
  -- both succeed, not resolve to a silent no-op for whoever writes second.
  PRIMARY KEY (uid, id)
);
CREATE INDEX IF NOT EXISTS idx_notes_pull ON notes(uid, server_seq);

CREATE TABLE IF NOT EXISTS blocks (
  id           TEXT NOT NULL,
  uid          TEXT NOT NULL,
  note_id      TEXT NOT NULL,
  parent_id    TEXT,                 -- nested blocks (toggles, list children)
  order_key    TEXT NOT NULL,
  type         TEXT NOT NULL,        -- paragraph|heading1..3|todo|bullet|numbered|quote|code|divider|image
  content      TEXT NOT NULL,        -- JSON: { text, checked, lang, attachmentId, ... }
  hlc          TEXT NOT NULL,
  server_seq   INTEGER NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (uid, id)
);
CREATE INDEX IF NOT EXISTS idx_blocks_pull ON blocks(uid, server_seq);
CREATE INDEX IF NOT EXISTS idx_blocks_note ON blocks(note_id, deleted);

CREATE TABLE IF NOT EXISTS themes (
  id           TEXT NOT NULL,
  uid          TEXT NOT NULL,
  name         TEXT NOT NULL,
  spec         TEXT NOT NULL,        -- JSON ThemeSpec
  hlc          TEXT NOT NULL,
  server_seq   INTEGER NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (uid, id)
);
CREATE INDEX IF NOT EXISTS idx_themes_pull ON themes(uid, server_seq);

CREATE TABLE IF NOT EXISTS attachments (
  id           TEXT NOT NULL,
  uid          TEXT NOT NULL,
  note_id      TEXT,
  r2_key       TEXT NOT NULL,
  mime         TEXT NOT NULL,
  size         INTEGER NOT NULL,
  hlc          TEXT NOT NULL,
  server_seq   INTEGER NOT NULL,
  deleted      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (uid, id)
);
CREATE INDEX IF NOT EXISTS idx_attach_pull ON attachments(uid, server_seq);

-- Entitlements are keyed ONLY on uid, which is what makes a purchase on iOS
-- unlock the feature on Android under the same login.
CREATE TABLE IF NOT EXISTS entitlements (
  uid              TEXT NOT NULL,
  entitlement      TEXT NOT NULL,     -- 'theme_pro' | 'cloud_sync'
  status           TEXT NOT NULL,     -- 'active' | 'expired' | 'grace' | 'revoked'
  source_platform  TEXT NOT NULL,     -- 'apple' | 'google'
  product_id       TEXT NOT NULL,
  original_txn_id  TEXT NOT NULL,
  purchased_at     INTEGER NOT NULL,
  expires_at       INTEGER,           -- NULL = non-consumable / lifetime
  updated_at       INTEGER NOT NULL,
  PRIMARY KEY (uid, entitlement)
);

-- Binds a store transaction to exactly one account, so a single purchase cannot
-- be replayed to unlock many accounts.
CREATE TABLE IF NOT EXISTS iap_links (
  platform         TEXT NOT NULL,
  original_txn_id  TEXT NOT NULL,
  uid              TEXT NOT NULL,
  purchase_token   TEXT,              -- Play purchase token; NULL on Apple
  created_at       INTEGER NOT NULL,
  PRIMARY KEY (platform, original_txn_id)
);
-- Play notifications identify a purchase only by its token, so we must be able
-- to resolve token -> uid directly.
CREATE UNIQUE INDEX IF NOT EXISTS idx_iap_token ON iap_links(purchase_token)
  WHERE purchase_token IS NOT NULL;

-- Raw store notifications, kept for dispute/refund forensics.
CREATE TABLE IF NOT EXISTS iap_events (
  id           TEXT PRIMARY KEY,
  platform     TEXT NOT NULL,
  notif_type   TEXT,
  uid          TEXT,
  payload      TEXT NOT NULL,
  received_at  INTEGER NOT NULL
);
