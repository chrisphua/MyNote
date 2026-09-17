# Changelog

Notable changes to MyNote. Format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/);
versions follow [SemVer](https://semver.org/). iOS and Android ship from the same
version number so a bug report maps to one commit.

## [Unreleased]

### Added

- **Sync protocol** — cursor-based push/pull over a single monotonic sequence per
  user, with hybrid logical clocks for conflict resolution and fractional
  indexing for ordering. Implemented three times (TypeScript, Swift, Kotlin) with
  shared test vectors to keep the encodings identical.
- **Cloudflare Worker backend** — D1 for notes, blocks, themes and entitlements;
  R2 for attachments; Firebase ID token verification against Google's JWKS.
- **Offline-first iOS app** — SwiftUI block editor over SwiftData, with a durable
  outbox, adaptive one/two-pane layout, and StoreKit 2 purchasing.
- **Offline-first Android app** — Compose block editor over Room, same durable
  outbox, window-size-class layout, and Play Billing v7.
- **Fully customizable themes** — colours for light and dark, typography, spacing,
  corners and page width, live-previewed against real content and synced between
  devices. Three presets are free; building your own is a one-time purchase.
- **Cross-platform entitlements** — purchases are recorded against the Firebase
  `uid`, so buying on one platform unlocks the feature on the other. Apple and
  Google receipts are verified server-side by re-reading authoritative state from
  the store rather than trusting the client.
- **CI/CD** — GitHub Actions for backend (test → staging → production with a
  smoke test), iOS (core tests → build → TestFlight on tag) and Android (tests →
  debug build → Play internal on tag), plus an automated code review on every PR.

### Fixed

- **Fractional index could hang the editor.** `between(nil, "0")` looped forever,
  because nothing sorts below `"0"` — `"00"` sorts *after* it. Generated keys now
  never end in the lowest digit, which guarantees room below any existing key.
  Caught by a 300-iteration front-insert test that hung for 14 minutes.
- **Tombstones violated a NOT NULL constraint.** Deleting a record the server had
  never seen failed, because SQLite validates NOT NULL on the proposed row before
  resolving `ON CONFLICT`. Deletes now use their own statement with placeholder
  values, and preserve existing content server-side for restore.
- **Play webhooks resolved the wrong account.** A notification was matched to any
  user holding that product id. Purchase tokens are now stored on `iap_links` and
  looked up directly.
