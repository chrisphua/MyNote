# Costs and margin

**Prices checked September 2026. Verify against Apple and Google before relying
on them for a decision.**

The short version: running MyNote costs **$114 a year** and nothing else. There
is no per-user cost, no bandwidth bill, and no bill that grows with success —
because there is no server.

## Why there is no infrastructure cost

Backups go into storage the user already pays for. A hundred users, a hundred
thousand users, a user with 40 GB of notes: all of it lands in their Google
Drive or their iCloud Drive, and none of it touches anything we own.

This also removes the entire class of problem that dominated the earlier design:
no egress bills, no storage quota to enforce, no rate limiting to stop someone
running up a bill, no database to migrate, no secrets to rotate, and nothing to
be breached. There is no copy of anyone's notes on our side to lose.

## Fixed costs

| Item | Cost | Notes |
|---|---|---|
| Apple Developer Program | **$99 / year** | Unavoidable to ship on iOS |
| Google Play Developer | **$25 once** | One-time, for the life of the account |
| Domain | ~**$15 / year** | For the privacy policy and support page, which both stores require |
| Servers, database, storage, bandwidth | **$0** | There are none |

**Year one: about $139. Every year after: about $114**, or $9.50 a month.

Google's $25 is genuinely one-time — it covers the account for life and any
number of apps. Apple's $99 is the only thing that recurs.

The store fees are the cheap part. The expensive part is *time*: a new personal
Play account must run a 14-day closed test before it can publish at all, and
neither store lets you sell anything until banking and tax details clear. See
[the launch timeline](DEPLOYMENT.md#launch-timeline--start-this-before-the-app-is-finished)
— create both accounts before the app is finished, so those clocks run while you
are still building.

> **Revenue today is zero by choice.** The app is free while it settles; see
> [MONETIZATION.md](MONETIZATION.md). The figures below are what the planned
> one-time purchase would yield once it is switched on. Until then the $114/year
> is simply a cost of shipping.

## Store commission

Both stores take **15%** for a small developer — Apple through the Small
Business Program (under $1M/year, **you must enrol**, it is not automatic) and
Google through its standard first-$1M rate.

| | Price | At 15% | At 30% |
|---|---|---|---|
| MyNote Pro | $14.99 | **$12.74** | $10.49 |

The stores collect and remit VAT/GST themselves, so that is what actually
reaches you before income tax.

> **Enrol in the Apple Small Business Program before your first sale.** It is a
> form, it takes minutes, and it is worth $2.25 on every sale.

## Break-even

At $12.74 net per sale, the $114 annual cost is covered by **nine sales a year**.
Year one, with the $25 Play fee, it is **eleven**.

After that, every sale is essentially pure margin. Not 99% — **100%**, because
the marginal cost of one more user is genuinely zero.

## At scale

| Sales / year | Net revenue | Costs | Profit |
|---|---|---|---|
| 10 | $127 | $114 | **$13** |
| 100 | $1,274 | $114 | **$1,160** |
| 1,000 | $12,740 | $114 | **$12,626** |
| 10,000 | $127,400 | $114 | **$127,286** |

The cost column does not move, because nothing in it scales with users.

## Why one-time rather than a subscription

The earlier design hosted storage, so it had a recurring cost and needed
recurring revenue: a lifetime price would have decayed into a loss as a paying
user's lifetime grew.

That reason is gone. Charging monthly for software with no monthly cost is
asking for money to cover an expense that does not exist, and people can tell.
A single purchase is also an easier sell, converts better, and removes
subscription management, grace periods, billing-retry handling and renewal
webhooks from the codebase entirely.

The trade is real: no recurring revenue, so growth has to come from new sales
rather than a compounding base. At these costs, that is an acceptable trade.

## What actually threatens the margin

Ranked by how likely each is to bite.

1. **Nobody buys.** Now the *only* risk. Nine sales a year is a low bar, but it
   is still the whole game, and there is no recurring revenue to smooth a slow
   month. This is where [MARKETING.md](MARKETING.md) earns its place.
2. **Apple's 30% instead of 15%.** Forgetting to enrol in the Small Business
   Program costs 15% of gross revenue forever.
3. **Refunds.** Both stores allow them, and a refunded purchase is gone. There
   is no server to revoke the entitlement, so a refunded user may keep Pro on a
   device that never checks in again. At this price it is not worth engineering
   against.
4. **Support load.** The real cost of this design is not money, it is time:
   "why won't my iPhone see my Android notes" has a genuine answer (they chose
   iCloud) and it will be asked. Hence the storage picker explaining it up front.

## Things deliberately not bought

| Tempting | Cost | Why not |
|---|---|---|
| Any backend | $5–25/mo | The entire point. It would also make us responsible for other people's notes. |
| RevenueCat | free, then 1% | Nothing left to validate: StoreKit and Play verify their own purchases, and the cross-platform hand-off is a file in the user's folder. |
| Crash reporting | $0–26/mo | Worth adding once there are users. Not on day one. |
