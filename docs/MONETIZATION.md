# Monetization

## What is free, and why

Unlimited notes, every block type, all three built-in themes, search, and the
entire editor — free, with no account, forever.

That is a deliberate position, not generosity. A note app people cannot trust
with their writing is worthless, and a trial that expires on someone's notes is
hostile. What is sold is *convenience on top of a complete app*: your own visual
design, and your notes on more than one device.

It is also the reason the margin works. A free user never touches the backend, so
a hundred thousand of them cost exactly nothing.

## Products

Identical ids on both stores, so one row in `backend/src/products.ts` serves an
Apple and a Google purchase and the mapping cannot drift.

| Product id | Type | Price | Unlocks |
|---|---|---|---|
| `io.mynote.themes.lifetime` | Non-consumable / one-time | $9.99 | `theme_pro` |
| `io.mynote.sync.monthly` | Auto-renewable / subscription | $2.99/mo | `cloud_sync` |
| `io.mynote.sync.yearly` | Auto-renewable / subscription | $19.99/yr | `cloud_sync` |

**Two products, not one bundle.** Someone who wants their own colours should not
be pushed into a recurring charge, and someone who wants sync should not pay for
theming they will never open. Bundling would raise ARPU and lower conversion; the
split also matches the actual cost structure — themes cost nothing to serve,
sync costs about a cent a month.

**Why sync is a subscription and themes are not.** Sync has a recurring cost, so
it needs recurring revenue. Themes are pure software: charge once, serve forever.
A lifetime unlock for something with an ongoing cost is a slow-motion loss.

## Cross-platform entitlement

The requirement: *pay on either platform, unlocked on both.*

```
Apple IAP   ──→ transactionId  ──┐
                                 ├──→ Worker ──→ verify with the store ──→ D1
Play Billing ──→ purchaseToken ──┘                                          │
                                                                            ▼
                                                  entitlements(uid, entitlement)
```

The whole mechanism is one line of schema:

```sql
PRIMARY KEY (uid, entitlement)
```

No platform column is consulted on read. An entitlement belongs to the Firebase
account, so signing in on Android surfaces an iOS purchase with no migration, no
linking step, and no code that knows which store paid.

**Purchases cannot be shared.** `iap_links` binds one `original_txn_id` to one
`uid` the first time it is seen; a second account presenting the same receipt
gets `409 purchase_already_linked`.

## How verification works

The client never asserts an entitlement. It sends a **lookup key** — Apple's
`transactionId` or Play's `purchaseToken` — and the Worker re-reads authoritative
state from the store's own API.

**Apple.** The Worker signs an ES256 JWT with the App Store Connect key and calls
`GET /inApps/v1/transactions/{id}`. The answer arrives over TLS from Apple's host
on a connection authenticated with our private key, so a forged id yields a 404
rather than a forged entitlement. This is also why we never had to implement
X.509 chain validation inside a Worker.

**Google.** The Worker exchanges a service-account JWT for an OAuth token and
calls the Play Developer API (`subscriptionsv2` or `products`), then
**acknowledges** the purchase. Acknowledging is not optional: Play auto-refunds
anything left unacknowledged for three days.

**Webhooks are untrusted.** App Store Server Notifications and Play RTDN only
tell us *which* purchase changed; the Worker re-fetches the truth before acting.
A spoofed webhook can at worst trigger a refresh that confirms reality.

Every notification is logged raw to `iap_events` for refund and dispute
forensics.

## Subscription lifecycle

| Event | Handling |
|---|---|
| Purchase | Verified, entitlement granted, acknowledged |
| Renewal | Store notification → re-fetch → `expires_at` extended |
| Cancellation | Stays active until `expires_at`; they paid for the period |
| Billing failure | **3-day grace period**, status `grace`, access continues |
| Expiry | Access ends. Notes stay on-device; nothing is deleted |
| Refund / chargeback | Revoked immediately via the voided-purchase notification |
| Upgrade monthly → yearly | Replaces the row; `PRIMARY KEY (uid, entitlement)` prevents duplicates |

The grace period exists because a card expiring should not lock someone out of
their own notes over a weekend.

## What happens when sync lapses

Nothing is deleted and nothing is held hostage. Notes remain fully readable and
editable on every device that already has them; only the syncing stops, and the
status line says so. Attachments already downloaded stay.

Holding someone's writing hostage would be both wrong and a support nightmare.

## Store review notes

Both stores reject on these, and all are handled:

- **Restore purchases** is visible in Settings and on the paywall (required).
- **Subscription terms** — renewal, price, period and how to cancel — are on the
  paywall itself, not buried (required).
- **Sign in with Apple** is offered wherever Google sign-in is (Apple requires it).
- **The app is usable without an account.** Gating a note app behind a login is a
  common rejection.
- **Privacy policy and terms** are linked from Settings and the paywall.
- **Prices come from the store**, never hard-coded, so every currency is right.

## Adding a product later

1. Create it in both consoles with the **same product id**.
2. Add one row to `PRODUCTS` in `backend/src/products.ts`.
3. Add the id to `PurchaseManager.ProductID` (iOS) and `BillingManager.Products`
   (Android).
4. Add a card to both paywalls.

Nothing else changes: verification, entitlement storage and cross-platform
unlocking are all generic over the product table.
