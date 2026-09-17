# Sync protocol

One endpoint does everything: `POST /v1/sync` pushes local changes and pulls
remote ones in the same round trip. Pushing first means a two-device conflict
resolves in one request instead of two.

Requires an active `cloud_sync` entitlement; without one the endpoint returns
`402` and the client shows the paywall. Everything else in the app works
regardless.

## Request

```jsonc
{
  "cursor": 412,        // highest serverSeq this device has durably applied
  "limit": 200,         // optional, max 500
  "changes": [          // optional, max 500 per request
    {
      "entity": "block",
      "id": "8f3c…",
      "hlc": "0000018f5a2b3c4d-0000-a1b2c3d4",
      "deleted": false,
      "fields": {
        "note_id": "n-1",
        "order_key": "a0V",
        "type": "paragraph",
        "content": "{\"text\":\"Hello\"}"
      }
    }
  ]
}
```

`fields` keys are the server's own column names, so no side keeps a translation
table. `content` and `spec` are JSON **strings**, not nested objects — the server
stores them verbatim in a TEXT column and only checks that they parse.

## Response

```jsonc
{
  "cursor": 431,
  "changes": [ /* same shape, plus "serverSeq" */ ],
  "hasMore": false,
  "serverTime": 1789600000000,
  "rejected": [ { "entity": "block", "id": "bad-1", "reason": "bad_block_type" } ]
}
```

A client loops while `hasMore` is true or its outbox is non-empty, so a device
returning after weeks offline catches up in one call.

## Hybrid logical clocks

```
0000018f5a2b3c4d-0000-a1b2c3d4
|--- millis ---| |ctr| |-node-|
     16 hex       4 hex  device
```

Fixed width and lexicographically sortable, so SQLite compares them with a plain
`>` and no custom collation.

Wall time alone is unusable here: two phones with clocks three seconds apart
would silently reorder each other's edits. The counter breaks ties within a
millisecond and guarantees a device's own edits are strictly increasing even when
its clock jumps backwards after an NTP resync.

**Rules**

- `tick(now)` before every local edit. Never hand-build a clock.
- `observe(remote, now)` when applying a pull, so this device never issues an
  edit that sorts older than something it has already seen.
- Clocks more than **24 hours** in the future are rejected. Otherwise one device
  with a badly wrong clock could write an HLC in 2400 and win every future
  conflict on that record, permanently.

**This is implemented three times — TypeScript, Swift, Kotlin — and the encodings
must match byte for byte.** Shared vectors are asserted in all three suites. A
change to padding or field order in one place silently corrupts conflict
resolution everywhere.

## Conflict resolution

Last-write-wins per record, by HLC. The comparison happens in SQL, inside the
upsert, which closes the gap between reading the current clock and writing:

```sql
INSERT INTO blocks (…) VALUES (…)
ON CONFLICT(id) DO UPDATE SET …
WHERE blocks.uid = excluded.uid AND excluded.hlc > blocks.hlc
```

The `uid` term is not decoration: without it, one account could overwrite
another's row by guessing its id.

Clients then re-check locally when applying the response, because an edit made
while the request was in flight can be newer than what comes back.

## Ordering: fractional indices

Notes and blocks order by a string key, not an integer position. Inserting
between two neighbours generates a key strictly between them, so an insert
rewrites exactly one row and two offline devices inserting at the same spot
interleave rather than collide.

Alphabet is `0-9A-Za-z` (base 62), compared lexicographically.

> **Invariant: a generated key never ends in `'0'`.**
>
> Nothing sorts below `"0"` — `"00"` sorts *after* it, not before — so
> `between(null, "0")` has no answer. An early version looped forever building
> `"000000…"`, and the front-insert test hung for fourteen minutes before it was
> caught. Keeping the last digit non-zero guarantees there is always room below
> any existing key.

Both implementations assert this, plus that 300 successive front-inserts stay
ordered and stay under 120 characters.

## Deletes

Tombstones, never hard deletes, or a device that was offline would never learn
the record is gone.

A tombstone syncs as `{"deleted": true, "fields": {}}`. The server keeps the
content for restore-from-trash but never returns it — deleting something should
not keep broadcasting it.

Deleting a record the server has never seen (created and deleted while offline)
needs its own SQL statement: SQLite validates `NOT NULL` on the proposed row
*before* resolving `ON CONFLICT`, so the ordinary upsert fails. The tombstone
path inserts placeholder values and, on an existing row, touches only the clock
and the flag.

## Cursors

Every write takes the next value from a single per-user counter, so all four
entity types share one sequence space and the cursor is one integer:

```sql
SELECT 'note' AS entity, … FROM notes  WHERE uid = ?1 AND server_seq > ?2
UNION ALL
SELECT 'block' AS entity, … FROM blocks WHERE uid = ?1 AND server_seq > ?2
…
ORDER BY server_seq ASC LIMIT ?3
```

The cursor is persisted **only after every change in the page is durable**, so a
crash mid-apply replays the page rather than skipping it.

## Validation

`backend/src/sync.ts` is the trust boundary. A change is rejected — not retried —
when it is malformed, and the id comes back in `rejected` so the client drops it
instead of looping forever.

| Reason | Meaning |
|---|---|
| `unknown_entity` | Not one of the four |
| `bad_id` | Empty or over 64 characters |
| `bad_clock` | Unparseable, or more than 24h ahead |
| `missing_<field>` | A required column was absent |
| `bad_block_type` | Not a known block type |
| `content_not_json` / `spec_not_json` | Not parseable JSON |
| `content_too_large` | Over 64 KB |
| `self_parent` | A record naming itself as its parent |

Unknown *keys* are dropped rather than rejected, so an older server stays
compatible with a newer client.

Limits: 500 changes per push, 500 per pull page, 64 KB per block, 32 KB per
theme, 25 MB per attachment.

## Client responsibilities

1. Write locally first. Return to the user immediately.
2. Queue the change in a **durable** outbox — it must survive a force-quit.
3. Debounce ~2s, then sync. Coalesce repeated edits to one record.
4. Remove from the outbox **only** on confirmation, or on explicit rejection.
5. On `402`, show the paywall. On a network error, keep the queue and retry.
6. Flush the backlog when connectivity returns.

## Other endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/v1/me` | Profile and entitlements |
| `GET` | `/v1/entitlements` | Entitlements only |
| `GET` | `/v1/storage` | Bytes used and quota |
| `POST` | `/v1/iap/apple/verify` | Verify a StoreKit transaction id |
| `POST` | `/v1/iap/google/verify` | Verify a Play purchase token |
| `PUT/GET/DELETE` | `/v1/attachments/:id` | Attachment bytes |
| `POST` | `/v1/webhooks/apple` | App Store Server Notifications V2 |
| `POST` | `/v1/webhooks/google` | Play RTDN via Pub/Sub |

## Error codes

| HTTP | `code` | Client should |
|---|---|---|
| 401 | `unauthenticated`, `token_expired` | Refresh the token, then retry |
| 402 | `payment_required` | Show the paywall |
| 409 | `purchase_already_linked` | Explain the purchase belongs to another account |
| 413 | `batch_too_large` | Split the push |
| 507 | `quota_exceeded` | Prompt to free space or upgrade |
