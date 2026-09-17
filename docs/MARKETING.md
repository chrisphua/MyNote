# Marketing

Store listings and social content are generated with
[`latent-spaces/brag`](https://github.com/latent-spaces/brag), driven from
`marketing/brag/` in this repo so the copy is version-controlled and reviewable
like everything else.

## Setup

```bash
git clone https://github.com/latent-spaces/brag ~/tools/brag
cd ~/tools/brag && ./install.sh     # follow the project's own README

export ANTHROPIC_API_KEY=...        # brag calls a model to draft copy
```

Then, from this repo:

```bash
brag generate --config marketing/brag/brag.config.json --target app-store
brag generate --config marketing/brag/brag.config.json --target tiktok
```

> Verify the install steps against brag's own README — this file records how we
> use it, not how it works.

## What is in `marketing/brag/`

| File | Purpose |
|---|---|
| `brag.config.json` | Product facts, positioning, tone, and the output targets |
| `product.md` | The long-form source of truth every generated asset draws from |
| `audiences.md` | Who we are talking to and what each group actually wants |
| `outputs/` | Generated drafts. **Review before publishing.** |

## Positioning

**The line:** *Notes that work offline, in a theme you actually chose.*

Two claims, both true and both checkable, because the market is crowded with note
apps making vague ones.

| Against | Our angle |
|---|---|
| Notion | Opens instantly, works on a plane, does not need an account |
| Apple Notes | Real theming, and it works on Android too |
| Obsidian | The same local-first promise without the setup or the plugin rabbit hole |
| Bear | Cross-platform, and themes you build rather than pick from a list |

**Do not claim:** end-to-end encryption (not implemented — see
[ARCHITECTURE.md](ARCHITECTURE.md)), real-time collaboration, or AI features.
Shipping a claim the app does not honour is how you earn one-star reviews and a
store rejection in the same week.

## Asset checklist

**App Store**
- 30-character name, 30-character subtitle
- 100 keywords (comma-separated, no spaces)
- Description leading with offline + theming
- 6.7" and 5.5" iPhone screenshots, plus 12.9" iPad
- Preview video, 15–30s

**Play Store**
- 30-character title, 80-character short description
- 4,000-character full description
- Feature graphic, 1024×500
- Phone, 7" and 10" tablet screenshots

**Social**
- TikTok / Reels: 9:16, 15–30s. The theme editor changing a page live is the
  single most watchable thing this app does — lead with it.
- Facebook / Instagram: 1:1 and 4:5 stills, the same before/after framing.

## Suggested cadence

| When | What |
|---|---|
| Pre-launch | Build-in-public posts; a waitlist page on the domain |
| Launch week | Product Hunt; r/productivity and r/androidapps; one TikTok a day |
| Ongoing | A theme showcase each week — user-made themes are free, credible content |

Screenshots and copy should be regenerated whenever the UI changes materially;
stale store screenshots are a common cause of refund requests.
