# Architecture

## The one rule

**An edit is saved locally and the user moves on.** Everything else in this
document follows from that. Sync is a background consequence of editing, never a
step the user waits for, and a device with no account and no connection is a
fully working app.

The corollary is the rule the code-review agent checks hardest: *a local edit
leaves the outbox only after the server confirms it.*

## Pieces and what each one owns

```
┌─────────────────────────┐        ┌──────────────────────────┐
│  iOS  (SwiftUI)         │        │  Android  (Compose)      │
│  ├─ SwiftData ──────────┤        │  ├─ Room ────────────────┤
│  ├─ MyNoteCore          │        │  ├─ :core                │
│  │   Hlc · FractionalIndex · SyncEngine · ThemeSpec         │
│  ├─ StoreKit 2          │        │  ├─ Play Billing 7       │
│  └─ Firebase Auth       │        │  └─ Firebase Auth        │
└───────────┬─────────────┘        └───────────┬──────────────┘
            │        HTTPS, Firebase ID token  │
            └──────────────┬───────────────────┘
                           ▼
              ┌────────────────────────────┐
              │   Cloudflare Worker        │
              │   /v1/sync                 │
              │   /v1/entitlements         │
              │   /v1/iap/{apple,google}   │
              │   /v1/attachments/:id      │
              │   /v1/webhooks/{apple,google}
              └──────┬──────────────┬──────┘
                     ▼              ▼
                ┌─────────┐   ┌──────────┐
                │   D1    │   │    R2    │
                │ SQLite  │   │  blobs   │
                └─────────┘   └──────────┘
```

| Component | Owns | Deliberately does not own |
|---|---|---|
| `backend/` | Conflict arbitration, entitlements, quota, tenant isolation | Any UI concern; any notion of "current note" |
| `MyNoteCore` / `:core` | Clocks, ordering, the wire format, the sync loop, the theme model | Persistence, UI, platform SDKs |
| Platform apps | Persistence, rendering, purchasing, auth UI | Conflict rules — those are in core, once per platform |
| Firebase Auth | Identity only | Notes. It never sees them. |

**Why the engine is a separate module on both platforms:** it makes the part that
is expensive to get wrong testable in milliseconds with no simulator and no
emulator. 65 of the project's 92 tests run that way.

## Data model

Four syncable entities — `note`, `block`, `theme`, `attachment` — each carrying:

- `hlc` — hybrid logical clock; the authority for who wins a conflict
- `server_seq` — assigned only by the server; what the pull cursor walks
- `deleted` — a tombstone, never a hard delete, so offline devices learn about it

Notes nest (like Notion pages) and blocks nest within a note. Both order by a
**fractional index**: a string strictly between its neighbours. An insert
therefore rewrites exactly one row, and two devices inserting at the same spot
interleave instead of colliding. See [SYNC-PROTOCOL.md](SYNC-PROTOCOL.md).

## Decisions worth knowing about

**Hybrid logical clocks over plain timestamps.** Two phones with clocks three
seconds apart would silently reorder each other's edits. An HLC keeps wall time
so ordering stays human-meaningful, but adds a counter that breaks ties and
guarantees a device's own edits are strictly increasing even if its clock jumps
backwards.

**HLCs over CRDTs.** A full text CRDT would give character-level merge, at the
cost of a large dependency, much more storage per block, and a great deal of
complexity. Last-write-wins *per block* means two people editing different
paragraphs merge cleanly and two people editing the same paragraph lose one
version — an acceptable trade for a personal note app, and revisitable later
without changing the transport.

**One sequence space per user, not per table.** All four tables share a single
counter, so the pull cursor is one integer and a `UNION ALL … ORDER BY
server_seq` gives a correct global ordering. Per-table cursors would need
four-way reconciliation on every page.

**Tombstones do not carry content.** A deleted record syncs as `{deleted: true}`
with empty fields. The server keeps the content for restore-from-trash, but never
sends it back — deleting something should not keep broadcasting it.

**Re-check the clock when applying a pull.** The server has already resolved
conflicts, but a local edit made *while the request was in flight* can still be
newer. Sync compares clocks again before overwriting, which is what stops a
round trip from eating a fresh keystroke.

**Entitlements key on `uid` alone.** No platform, no device, no receipt is
consulted at read time. That single choice is what makes "buy on iOS, unlocked
on Android" work, and it is why the check is one indexed lookup.

**Store webhooks are not trusted.** A notification from Apple or Google only
tells us *which* purchase changed; the Worker then re-reads authoritative state
from the store's own API over authenticated TLS. A forged webhook can at worst
cause a refresh that confirms the truth — never grant an entitlement. It also
means we never had to implement X.509 chain validation inside a Worker.

**Firebase for identity, our own backend for data.** Firebase Auth is free for
Google, Apple and email, and absorbs password resets, email verification and
account recovery. Firestore was rejected because a block editor generates
enormous per-document read counts and would bill unpredictably with *editing*
rather than with users.

**The apps run without credentials.** With no `GoogleService-Info.plist` or
`google-services.json` present, both apps start in local-only mode and say so.
A fresh clone builds and runs; CI does not need secrets to verify a PR.

## Security boundaries

| Boundary | Enforced where |
|---|---|
| Request identity | `backend/src/auth.ts` — RS256 verified against Google's JWKS; `iss`, `aud`, `exp`, `iat` all checked |
| Tenant isolation | Every query filters on `uid`, **including the upsert conflict `WHERE`**, so one account cannot overwrite another's row by guessing an id |
| Input validation | `backend/src/sync.ts` — the single trust boundary; past it a change is treated as safe to write |
| Clock poisoning | Changes more than 24h in the future are rejected, so a bad clock cannot win every future conflict |
| Purchase replay | `iap_links` binds one `original_txn_id` to one account |
| Paid features | Checked server-side (`402` from `/v1/sync`), not only in the UI |
| Theme input | `ThemeSpec.sanitized()` on both platforms before anything reaches a renderer |
| Object keys | Attachment ids are regex-checked before becoming an R2 key |

## Known gaps

Honest list of what is not built yet.

- **No rate limiting.** A paid account could hammer `/v1/sync`. Should land
  before public launch — see [COSTS.md](COSTS.md).
- **Attachment upload/download is server-side only.** Works and is cheap, but a
  presigned direct-to-R2 upload would cut Worker CPU on large files.
- **No retention/GC job.** Tombstones and orphaned R2 objects accumulate. Needs a
  scheduled Worker.
- **No E2E encryption.** Notes are encrypted in transit and at rest by Cloudflare,
  but the server can read them. Real E2E would break server-side search and
  conflict resolution; worth designing deliberately rather than bolting on.
- **`attachment` entities have no local row.** They sync as metadata, but the
  clients do not yet cache the bytes.
- **Numbered lists always render "1."** Real numbering needs sibling indices.
- **No iOS UI tests / Android instrumentation tests.** Logic is well covered;
  the view layers are not.
