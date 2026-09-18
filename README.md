# MyNote

A Notion-style block editor that works offline, backs up to storage **you**
already own, and lets you build your own theme.

Native on both platforms — SwiftUI on iOS, Jetpack Compose on Android. **No
servers, no accounts, no subscription.**

```
iOS (SwiftUI + SwiftData)  ─┬─→  iCloud Drive      (Apple devices)
                            └─→  Google Drive      (everything)
                                       ▲
Android (Compose + Room)   ──────────-─┘
```

## Why it is built this way

**Your notes live in your storage.** There is no MyNote server. Backups go to a
folder in your own Google Drive or iCloud Drive that you can open, inspect and
delete yourself. We never see them, and there is no hosting bill to pass on to
you.

**Local first, always.** Every edit is written to the device's own database and
the UI returns immediately. Backing up is a background consequence, never
something typing waits for. The app is fully usable with no account and no
connection.

**Each device writes one file, and never another's.** That single rule removes
write conflicts entirely — there is no file two devices can both write, so there
is nothing to lock. Merging happens on read, by hybrid logical clock.

**No account to create.** Google Drive asks for Drive permission and nothing
else. iCloud asks for nothing at all. MyNote has no concept of a user.

## Pick your storage

| | Works on | Sign-in |
|---|---|---|
| **This device only** | — | none |
| **iCloud Drive** | iPhone, iPad, Mac | none — already signed in |
| **Google Drive** | **iPhone, iPad *and* Android** | one Drive permission prompt |

> **iCloud Drive cannot reach Android.** Apple publishes no iCloud Drive API for
> third-party Android apps. If you use both platforms, choose Google Drive. The
> storage picker says this before you choose, not after you switch phones.

## Layout

| Path | What it is |
|---|---|
| `ios/MyNoteCore/` | Swift package: merge engine, clocks, ordering, theme model, file format |
| `ios/MyNote/` | SwiftUI app + iCloud Drive and Google Drive providers |
| `android/core/` | Kotlin JVM module: the same engine, byte-identical file format |
| `android/app/` | Compose app + Google Drive provider |
| `docs/` | Architecture, backup format, costs, deployment, marketing |
| `.claude/agents/` | The code-review subagent run after each feature |

## Getting started

```bash
# iOS — core tests need no simulator
cd ios/MyNoteCore && swift test
cd ios && xcodegen generate && open MyNote.xcodeproj

# Android
cd android
./gradlew :core:test
./gradlew :app:assembleDebug
```

Both apps build and run **with no credentials at all**. Without a Google OAuth
client id, Drive backup is simply not offered — iCloud and local-only still
work. Nothing to configure to try it. See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
to turn Drive on.

## Dependencies

**iOS: none.** Google Drive is reached through its REST API with a hand-rolled
PKCE flow, so there is no SDK in the binary and nothing to keep current.

**Android: four** — Compose, Room, Play Billing, and Google's authorization
client (used only to obtain a Drive scope token).

## Tests

| Suite | Count | Runs in |
|---|---|---|
| `ios/MyNoteCore` (swift-testing) | 40 | <1s |
| `android/core` (JUnit) | 52 | ~2s |

They cover the things that are expensive to get wrong: merge and conflict
resolution, that a device never writes another's file, that a failed upload
loses nothing, cross-platform clock and file-format encoding, and the
ordering-key invariant.

## Money

**Everything is free right now.** No paywall, no in-app purchase, no account.
Custom themes and cloud backup are unlocked for everyone while the app settles.

A one-time purchase is planned once it is stable and published — the code is
written and switched off behind `AppFeatures.paidFeaturesEnabled`. Running
MyNote costs **$114/year** in developer fees and nothing per user, so there is
no hurry. See [docs/MONETIZATION.md](docs/MONETIZATION.md) and
[docs/COSTS.md](docs/COSTS.md).

## Docs

- [Architecture](docs/ARCHITECTURE.md) — how the pieces fit, and what each one owns
- [Backup format](docs/BACKUP-FORMAT.md) — what lands in your Drive, and the merge rules
- [Costs and margin](docs/COSTS.md) — unit economics and break-even
- [Monetization](docs/MONETIZATION.md) — the product, and how a purchase crosses platforms
- [Deployment](docs/DEPLOYMENT.md) — CI/CD, secrets, first-time setup
- [Marketing](docs/MARKETING.md) — store listings and social content with brag
- [Changelog](CHANGELOG.md)
