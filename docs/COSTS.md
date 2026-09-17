# Costs and margin

**Prices checked September 2026. Verify against the providers before relying on
them for a decision — Apple, Google and Cloudflare all change terms.**

The short version: serving one syncing user costs about **one cent a month**, and
roughly **six paying subscribers** covers every fixed cost you have. The business
risk here is getting users, not paying for them.

## Why it is this cheap

Three structural decisions, in order of how much they matter.

**1. Free users never touch the backend.** Sync is the paid feature, so a free
user's notes live entirely on their device. A hundred thousand free users cost
exactly $0. Most note apps fail here: they sync everyone, then discover the free
tier is the whole bill.

**2. R2 charges nothing for egress.** This is the one that would have sunk an S3
build. A sync app's defining traffic pattern is users re-downloading their own
attachments onto a new device — pure egress. S3 charges ~$0.09/GB for that; R2
charges zero. At 500 GB/month of downloads that is the difference between $45 and
$0.

**3. Notes are tiny.** A heavy user with a thousand notes is a few megabytes of
text. The storage that costs real money is images, and those are capped by quota.

## Fixed costs

| Item | Cost | Notes |
|---|---|---|
| Apple Developer Program | **$99 / year** | Unavoidable to ship on iOS |
| Google Play Developer | **$25 once** | One-time, for the life of the account |
| Domain | ~**$15 / year** | For the privacy policy and support page, which both stores require |
| Cloudflare Workers | **$0** → $5/mo | Free to 100k requests/day; paid plan needed past roughly 300 active syncing users |
| Cloudflare D1 | **$0** | 5 GB and generous row limits included on the Workers plan |
| Cloudflare R2 | **$0** → $0.015/GB/mo | First 10 GB free, and **no egress charge** at any size |
| Firebase Auth | **$0** | Free for Google, Apple and email sign-in |

**Year one, pre-revenue: about $139.** After the free tiers are exhausted, about
$174/year (≈ $14.50/month).

## Store commission

Both stores take **15%** for a small developer — Apple through the Small Business
Program (under $1M/year, **you must enrol**, it is not automatic) and Google
through its standard first-$1M rate. Without Apple's programme it is 30% there.

| Product | Price | At 15% | At 30% |
|---|---|---|---|
| Custom themes (one-time) | $9.99 | **$8.49** | $6.99 |
| Cloud sync (monthly) | $2.99 | **$2.54** | $2.09 |
| Cloud sync (yearly) | $19.99 | **$16.99** | $13.99 |

The stores collect and remit VAT/GST themselves, so these are what actually
reaches you before income tax.

> **Enrol in the Apple Small Business Program before your first sale.** It is a
> form, it takes minutes, and it is worth $1.50 on every $9.99 sale.

## What one syncing user costs per month

Assuming an active user: ~300 sync requests a day, a few thousand row writes, and
50 MB of attachments.

| Resource | Usage | Cost |
|---|---|---|
| Worker requests | ~9,000/mo | $0.0027 |
| D1 row writes | ~3,000/mo | $0.0030 |
| D1 row reads | ~30,000/mo | ~$0.0000 |
| R2 storage | 50 MB | $0.0008 |
| R2 egress | any | **$0.00** |
| **Total** | | **≈ $0.007** |

Call it **$0.01/month** with headroom.

Against $2.54 net on a monthly subscription that is a **99.6% gross margin**. Even
a user who fills their entire 1 GB quota costs $0.015/month in storage — still
under 1% of what they pay. There is no plausible individual user who is
unprofitable.

## Break-even

Fixed costs of ~$14.50/month are covered by:

- **6 monthly subscribers** ($2.54 each), or
- **11 yearly subscribers** over the year ($16.99 each), or
- **21 theme unlocks** in year one ($8.49 each)

## At scale

| Paying sync users | Net revenue/mo | Infra/mo | Profit/mo |
|---|---|---|---|
| 10 | $25 | $0 (free tier) | **$13** |
| 100 | $254 | $0–5 | **$235** |
| 1,000 | $2,541 | ~$15 | **$2,512** |
| 10,000 | $25,410 | ~$50 | **$25,346** |

Infrastructure is a rounding error at every size. Assumes monthly subscribers at
$2.99 and the $14.50/month fixed cost.

## What actually threatens the margin

Ranked by how likely each is to bite.

1. **Nobody buys.** The only real risk. At a 2% free-to-paid conversion you need
   ~300 downloads to reach break-even, which is achievable, but it is still the
   whole game. This is where the marketing tooling in
   [MARKETING.md](MARKETING.md) earns its place.
2. **Apple's 30% instead of 15%.** Forgetting to enrol in the Small Business
   Program costs 15% of gross revenue forever. Margin survives; it still stings.
3. **Refund abuse.** A refunded purchase is revoked server-side, and Play
   auto-refunds anything left unacknowledged for three days — which is why the
   backend acknowledges immediately.
4. **A user scripting the sync API.** Rate limiting is not implemented yet. A
   paid account hammering `/v1/sync` could run up Worker requests. Worth adding
   before public launch; see the open item in [ARCHITECTURE.md](ARCHITECTURE.md).
5. **Attachment storage growth.** Capped at 1 GB per paid account and enforced
   server-side before the write, so it cannot run away.

## Things deliberately not bought

| Tempting | Cost | Why not |
|---|---|---|
| RevenueCat | free, then 1% of revenue | Receipt validation is ~350 lines we already own. 1% forever is real money and the logic rarely changes. |
| Supabase | $25/mo flat past free tier | Would be a fixed cost before the first customer, and it bills storage egress. |
| Firestore | per-document reads | A block editor generates enormous read counts; costs would scale unpredictably with *editing*, not with users. |
| Sentry / analytics | $0–26/mo | Worth adding once there are users to learn from. Not on day one. |
