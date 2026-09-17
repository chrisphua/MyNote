# Deployment

Everything ships from GitHub Actions. Nothing is deployed from a laptop.

| Workflow | Trigger | Does |
|---|---|---|
| `backend.yml` | push to `main` under `backend/` | test → migrate+deploy staging → **manual approval** → migrate+deploy production → smoke test |
| `ios.yml` | push / PR under `ios/`, tag `ios-v*` | core tests → build → TestFlight on tag |
| `android.yml` | push / PR under `android/`, tag `android-v*` | core tests → debug build → Play internal on tag |
| `code-review.yml` | every non-draft PR | automated review against `.claude/agents/code-reviewer.md` |

Releases are cut by **tagging**, so merging to `main` never ships an app by
itself:

```bash
git tag ios-v0.1.0     && git push origin ios-v0.1.0
git tag android-v0.1.0 && git push origin android-v0.1.0
```

Migrations always run before the Worker that reads them, so a new column exists
by the time the code needing it is live. That makes every migration necessarily
**backwards-compatible** — add columns, never rename or drop in the same release.

---

## First-time setup

Roughly two hours end to end, most of it waiting on store consoles.

### 1. Cloudflare — the backend

```bash
cd backend
npx wrangler login

npx wrangler d1 create mynote
npx wrangler d1 create mynote-staging
npx wrangler r2 bucket create mynote-attachments
npx wrangler r2 bucket create mynote-attachments-staging
```

Paste the two database ids into `wrangler.toml`, then:

```bash
npm run migrate:remote
npx wrangler deploy
```

**Free tier limits:** 100k Worker requests/day, 5 GB D1, 10 GB R2. Past roughly
300 active syncing users you need Workers Paid at $5/month. See
[COSTS.md](COSTS.md).

### 2. Firebase — identity only

Create a project at [console.firebase.google.com](https://console.firebase.google.com).
Under **Authentication → Sign-in method**, enable **Google**, **Apple** and
**Email/Password**.

Add two apps and download the config:

| Platform | Bundle / package | File | Goes in |
|---|---|---|---|
| iOS | `io.mynote.app` | `GoogleService-Info.plist` | `ios/MyNote/Resources/` |
| Android | `io.mynote.app` | `google-services.json` | `android/app/` |

Both are **gitignored**. Without them the apps run local-only, which is exactly
what CI does on pull requests.

Set the project id on the Worker:

```bash
# wrangler.toml → [vars] FIREBASE_PROJECT_ID = "your-project-id"
npx wrangler deploy
```

> Sign in with Apple must be enabled in the Apple Developer portal too, and
> Apple **requires** it in any app offering Google sign-in. Skipping it is a
> guaranteed review rejection.

### 3. App Store Connect — iOS

1. Register the bundle id `io.mynote.app`, with the **In-App Purchase** and
   **Sign in with Apple** capabilities.
2. Create the three products from [MONETIZATION.md](MONETIZATION.md).
3. **Enrol in the Small Business Program.** 15% instead of 30%. Do this before
   your first sale — it is worth $1.50 on every $9.99 unlock.
4. Create an **App Store Connect API key** (Users and Access → Integrations),
   role *App Manager*. Keep the `.p8`; it downloads once.
5. Point **App Store Server Notifications V2** at
   `https://<your-worker>/v1/webhooks/apple`.

### 4. Play Console — Android

1. Create the app with package `io.mynote.app`.
2. Create the same three products.
3. Create a **service account** in Google Cloud with the *Android Publisher*
   role, grant it access in Play Console, and download its JSON key.
4. Enable **Real-time developer notifications** via Pub/Sub, pushing to
   `https://<your-worker>/v1/webhooks/google?key=<PUBSUB_SHARED_SECRET>`.

Generate an upload keystore and **back it up somewhere you will not lose it** —
losing it means you can never update the app under the same listing:

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias mynote
```

### 5. Worker secrets

```bash
cd backend
npx wrangler secret put APPLE_PRIVATE_KEY       # contents of the .p8
npx wrangler secret put GOOGLE_SA_PRIVATE_KEY   # private_key from the SA JSON
npx wrangler secret put PUBSUB_SHARED_SECRET    # any long random string
```

And in `wrangler.toml` under `[vars]`: `APPLE_ISSUER_ID`, `APPLE_KEY_ID`,
`GOOGLE_SA_EMAIL`, `FIREBASE_PROJECT_ID`.

### 6. GitHub secrets

Repository → Settings → Secrets and variables → Actions.

| Secret | From |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare → My Profile → API Tokens (*Edit Cloudflare Workers*) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare dashboard sidebar |
| `ANTHROPIC_API_KEY` | console.anthropic.com — used by the PR review |
| `IOS_GOOGLE_SERVICE_INFO_PLIST` | `base64 -i GoogleService-Info.plist` |
| `ANDROID_GOOGLE_SERVICES_JSON` | `base64 -i google-services.json` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key |
| `ASC_PRIVATE_KEY` | `base64 -i AuthKey_XXXX.p8` |
| `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION` | fastlane match certificate repo |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i release.jks` |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | your keystore |
| `PLAY_SERVICE_ACCOUNT_JSON` | the service account JSON, verbatim |

Also add a repository **variable** `PRODUCTION_API_URL` for the deploy smoke test.

Create three **environments** — `staging`, `production`, `ios-release`,
`android-release` — and add a required reviewer to `production` so a backend
release is always a deliberate act.

### 7. Signing certificates (iOS)

```bash
cd ios
bundle install
bundle exec fastlane match appstore
```

`match` keeps certificates in a private git repo so CI and your laptop use the
same ones. Alternatively use Xcode Cloud-style automatic signing and drop the
`match` step from `Fastfile`.

---

## Running locally

```bash
# Backend, against a local D1 and R2 — no Cloudflare account needed
cd backend && npm install && npm run migrate:local && npm run dev

# Point the apps at it
#   iOS:     ios/MyNote/Info.plist → MyNoteAPIBaseURL
#   Android: android/app/build.gradle.kts → API_BASE_URL (debug)
```

To exercise purchases without spending money: iOS uses a StoreKit configuration
file in the scheme; Android needs a signed build uploaded to the internal test
track with your account added as a licence tester.

## Rollback

```bash
# Backend — Cloudflare keeps previous versions
cd backend && npx wrangler rollback

# iOS — expire the TestFlight build, or reject the App Store submission
# Android — halt the staged rollout in Play Console
```

Mobile rollback is slow and partial by nature, which is why the backend keeps
migrations additive: a client one version behind must keep working.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `402` from `/v1/sync` | No active `cloud_sync` entitlement. Expected for free accounts. |
| `401 bad_token` | `FIREBASE_PROJECT_ID` on the Worker does not match the app's Firebase project. |
| Purchases never unlock | Webhook URL wrong, or the Worker's IAP secrets are unset. Check the `iap_events` table. |
| Play refunds a purchase after 3 days | It was never acknowledged. The Worker does this; confirm the service account has *Android Publisher*. |
| Android build fails on `google-services.json` | Only applied when the file exists — confirm the CI step wrote it. |
| iOS build cannot find the Xcode project | It is generated, not committed. Run `xcodegen generate`. |
