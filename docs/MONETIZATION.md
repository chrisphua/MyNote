# Monetization

## One product

**MyNote Pro — $14.99, paid once.** Unlocks custom themes and cloud backup.

Product id on both stores: `com.chrisphua.MyNote.pro`, a non-consumable / one-time purchase.

Everything else is free forever: unlimited notes, every block type, all three
built-in themes, search, and the whole editor.

## Why one-time, and why not a subscription

There is no server, so there is no recurring cost. Charging monthly for software
with no monthly cost is asking for money to cover an expense that does not
exist, and people can tell.

It also deletes a great deal of code and a whole category of bugs: no renewals,
no grace periods, no billing-retry handling, no expiry checks, no subscription
state machine, no webhooks, and nothing to get wrong when someone's card expires
over a weekend.

The trade: no recurring revenue. At $114/year of running costs, that is fine —
see [COSTS.md](COSTS.md).

## What is free, and why

A note app people cannot trust with their writing is worthless, and a trial that
expires on someone's notes is hostile. What is sold is *convenience on top of a
complete app*: your own visual design, and your notes on more than one device.

## How a purchase crosses platforms

The requirement: *pay on either platform, unlocked on both.*

With no server there is nowhere neutral to record that someone paid. So the
receipt travels with the notes:

```
Buy on iOS  ──→ StoreKit verifies ──→ license.json written into the user's Drive
                                              │
Install on Android ──→ connect same Drive ──→ read license.json ──→ Pro unlocked
```

**Free users can connect a folder.** They merge what is there and upload
nothing. That is deliberate: without read access there would be no way to
discover a licence bought on the other platform, and the chicken-and-egg would
make cross-platform purchase impossible.

**iCloud cannot do this.** Apple publishes no iCloud Drive API for Android, so a
purchase only travels between platforms via Google Drive. Someone on iCloud who
later buys an Android phone needs to restore the purchase through Play, or
switch to Drive.

## The threat model, stated plainly

| Path | Strength |
|---|---|
| StoreKit `Transaction.currentEntitlements` (iOS) | **Strong.** Apple verifies its own signature; we trust the OS. |
| Play `queryPurchasesAsync` (Android) | **Strong.** Play verifies its own purchase; we acknowledge it. |
| `license.json` in the folder | **Weak by design.** It sits in storage the user controls, so a determined person could forge it. |

That last row is a deliberate choice, not an oversight. Forging the file buys
someone a one-time purchase they could have made for the price of a sandwich,
and the alternative is running a server purely to police it — reintroducing
hosting costs, an account system, and custody of everyone's notes, to protect
$12.74. Not worth it.

Entitlements are combined as a **union**, never an intersection: a purchase made
on the other platform exists only in the file, and one made here may not be
uploaded yet, so neither may revoke the other.

## Refunds

Both stores allow refunds, and there is no server to revoke an entitlement.
StoreKit reports a revocation and iOS drops Pro; Play does the same on the
device that asks. A device that never checks in again may keep Pro. At this
price, engineering against that costs more than it saves.

## Store review notes

Both stores reject on these, and all are handled:

- **Restore purchase** is visible in Settings and on the paywall (required).
- **The app is usable without an account.** Gating a note app behind a login is
  a common rejection — MyNote has no accounts at all.
- **Privacy policy and terms** are linked from Settings and the paywall.
- **The price comes from the store**, never hard-coded, so every currency is right.
- **No subscription terms needed**, because there is no subscription.
- Google Drive uses `drive.file` only — per-file access to files the app
  created. Requesting `drive` or `drive.readonly` would trigger a restricted
  scope security assessment.

## Turning it on

1. Flip `paidFeaturesEnabled` / `PAID_FEATURES_ENABLED` to `true`.
2. Create the product in both stores, and complete the paid-apps agreement plus
   banking and tax details — see [DEPLOYMENT.md](DEPLOYMENT.md).
3. **Decide what happens to people who already installed it free.** They will
   see a paywall appear over features they already had, which reads as a
   takeaway however it is worded. The usual answer is to grandfather them: write
   a marker at first launch and treat anyone carrying it as Pro. That marker has
   to exist *before* those users arrive, so this is a decision to make early —
   not on the day the switch is flipped.
4. Re-read this document; the verification and refund behaviour below is already
   implemented and unchanged.

## Adding a product later

The licence file already carries an `entitlements` **list**, so splitting Pro
into separate purchases later needs no new file format — add the product id,
map it to a new entitlement string, and gate on it.
