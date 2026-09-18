# Deployment

Everything ships from GitHub Actions. There is no backend to deploy — only two
apps.

| Workflow | Trigger | Does |
|---|---|---|
| `ios.yml` | push / PR under `ios/`, tag `ios-v*` | core tests → build → TestFlight on tag |
| `android.yml` | push / PR under `android/`, tag `android-v*` | core tests → debug build → Play internal on tag |
| `code-review.yml` | every non-draft PR | automated review against `.claude/agents/code-reviewer.md` |

Releases are cut by **tagging**, so merging to `main` never ships by itself:

```bash
git tag ios-v0.2.0     && git push origin ios-v0.2.0
git tag android-v0.2.0 && git push origin android-v0.2.0
```

---

## Launch timeline — start this before the app is finished

The store accounts are the long pole, not the code. Almost everything below is
waiting on someone else, and none of it can be rushed at the end.

**Create both developer accounts on day one.** The fees are small, the waiting is
not, and every clock below runs in parallel with development.

### What each store costs

| | Fee | Recurring? |
|---|---|---|
| **Google Play** | **$25** | **No** — one-time, covers the account for life, unlimited apps |
| **Apple Developer Program** | **$99** | **Yes**, annually |

### What each store makes you wait for

**Google Play — the closed-testing requirement.** A **personal** developer
account created since late 2023 cannot publish straight to production. It must
first run a **closed test with a group of testers, opted in and running
continuously for 14 days**, and then *apply* for production access — which is
itself reviewed.

> **Check the current tester count in Play Console** under *Publishing overview*.
> It launched at 20 and has since been reduced at least once, so any number
> written here will go stale. Treat the 14-day duration as the fixed part.

An **organisation** account is exempt from this, but needs a **D-U-N-S number**,
which is free and typically takes a few business days to issue.

Recruiting testers is the part people underestimate. They must each *accept the
opt-in link and keep the build installed* — friends, a Discord, a subreddit, a
mailing list. Start collecting names early.

**Both stores — identity verification.** Apple and Google both verify who you
are before you can publish. Allow days, not hours.

**Both stores — you cannot sell anything until payments are set up.** This is the
one that most often blocks a launch at the last moment:

- **Apple:** the *Paid Applications Agreement* must be accepted, and banking and
  tax forms completed, in App Store Connect → Business. Until then
  `com.chrisphua.MyNote.pro` cannot leave "Missing Metadata", and the paywall has no price
  to show.
- **Google:** a payments profile and merchant account must exist before an
  in-app product can be activated.

Tax forms in particular can bounce back for correction, so do them first.

### A realistic order of operations

| When | Do |
|---|---|
| **Now** | Create both developer accounts. Pay the $25 and the $99. Begin identity verification. |
| **Now** | Start Apple's Paid Applications Agreement and both payment/tax profiles. |
| **Now** | If going the organisation route on Google, request the D-U-N-S number. |
| **While building** | Create `com.chrisphua.MyNote.pro` on both stores. Enrol in the Apple Small Business Program. |
| **First working build** | Push to Play **closed testing** and start the 14-day clock. Recruit testers. |
| **While the clock runs** | TestFlight on iOS, store listings, screenshots, privacy policy, support page. |
| **Day 14+** | Apply for Play production access. |
| **After approval** | Submit both. Expect roughly 1–3 days of review each, occasionally longer for a first submission. |

**Budget 3–4 weeks** between "the app is ready" and "it is live on both stores,"
almost none of which is engineering. If you create the accounts today, most of
that runs down while you are still writing code.

### Things that will get a first submission rejected

All of these are already handled in the app, but they are worth knowing, because
a rejection costs another review cycle:

- No visible **Restore purchase** control (both stores require one).
- Requiring an account to use the app. MyNote has none, which is the safe side
  of this rule.
- A missing or unreachable **privacy policy** and **support URL** — both are
  mandatory, and both need the domain live.
- A **data safety / privacy nutrition label** that does not match reality.
  MyNote's is unusually simple: no data is collected, because there is no
  server. Say exactly that.
- Google Drive access requesting a scope wider than `drive.file` — see section 1.

---

## First-time setup

Shorter than it used to be: there is no Cloudflare account, no database, no
Firebase project and no server secrets.

### 1. Google Cloud — Drive access

Needed only for Google Drive backup. Skip it and the app still ships with iCloud
and local-only.

1. Create a project at [console.cloud.google.com](https://console.cloud.google.com).
2. Enable the **Google Drive API**.
3. Configure the **OAuth consent screen** as External. Add the single scope
   `.../auth/drive.file`.
4. Create OAuth client ids:
   - **iOS** — bundle id `com.chrisphua.MyNote`
   - **Android** — package `com.chrisphua.mynote` plus your signing certificate SHA-1
   - **Web** — needed as the `serverClientId` for Android's offline access

> **`drive.file` needs no security assessment.** It grants per-file access to
> files the app created. Requesting `drive` or `drive.readonly` instead would
> put you into Google's restricted-scope review, which is slow and expensive.
> Do not widen the scope.

**Publish the consent screen** before release, or sign-in is capped at 100 test
users.

### 2. Apple — iCloud and the store

1. Register the bundle id `com.chrisphua.MyNote` with **iCloud** (CloudKit/Documents)
   and **In-App Purchase** capabilities.
2. Create the iCloud container `iCloud.com.chrisphua.MyNote`.
3. Accept the **Paid Applications Agreement** and complete banking and tax
   details under Business. Until this is done the in-app purchase stays in
   "Missing Metadata" and the paywall has no price to show.
4. Create the in-app purchase `com.chrisphua.MyNote.pro`, non-consumable, $14.99.
5. **Enrol in the Small Business Program.** 15% instead of 30%. Do this before
   your first sale.
6. Create an **App Store Connect API key** (Users and Access → Integrations),
   role *App Manager*. Keep the `.p8`; it downloads once.

### 3. Play Console

**$25, one-time.** Note the closed-testing requirement for personal accounts in
[Launch timeline](#launch-timeline--start-this-before-the-app-is-finished) —
it adds at least two weeks before you can publish, so start it early.

1. Create the app with package `com.chrisphua.mynote`.
2. Set up the **payments profile** — an in-app product cannot be activated
   without one.
3. Create the in-app product `com.chrisphua.mynote.pro`, one-time, $14.99.
4. Create a **service account** with the *Android Publisher* role for CI
   uploads.

Generate an upload keystore and **back it up somewhere you will not lose it** —
losing it means you can never update the app under the same listing:

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias mynote
```

### 4. GitHub secrets

Repository → Settings → Secrets and variables → Actions.

| Secret | From |
|---|---|
| `ANTHROPIC_API_KEY` | console.anthropic.com — used by the PR review |
| `IOS_GOOGLE_OAUTH_CLIENT_ID` | the iOS OAuth client id |
| `ANDROID_GOOGLE_OAUTH_CLIENT_ID` | the **Web** OAuth client id (Android needs it for offline access) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key |
| `ASC_PRIVATE_KEY` | `base64 -i AuthKey_XXXX.p8` |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i release.jks` |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | your keystore |
| `PLAY_SERVICE_ACCOUNT_JSON` | the service account JSON, verbatim |

Create two **environments**, `ios-release` and `android-release`, and add a
required reviewer to each so a store submission is always a deliberate act.

### 5. Signing (iOS)

Signing is **Xcode-managed**, matching how MyPlaylist ships — there is no
`match` repo to maintain. Xcode creates the distribution certificate, the App ID
and the iCloud container on first archive, provided the Apple ID that owns the
team is signed in under Xcode → Settings → Accounts.

For a first build, skip fastlane entirely:

> Xcode → **Product → Archive** → **Distribute App** → **TestFlight & App Store**

After that, `bundle exec fastlane beta` does the same thing with a build-number
bump. In CI, the App Store Connect API key needs **App Manager** rights so it can
create the certificate and profile on the runner.

---

## Running locally

```bash
cd ios/MyNoteCore && swift test
cd ios && xcodegen generate && open MyNote.xcodeproj

cd android && ./gradlew :core:test :app:assembleDebug
```

Neither app needs credentials to build or run. To try Google Drive locally, set
`MyNoteGoogleClientID` in `ios/MyNote/Info.plist`, or export
`GOOGLE_OAUTH_CLIENT_ID` before the Gradle build.

To exercise the purchase without spending money: iOS uses a StoreKit
configuration file in the scheme; Android needs a signed build on the internal
test track with your account as a licence tester.

## Verifying on a real device

**Run every release candidate on a physical device before uploading.** A
simulator does not apply entitlements, so anything gated on one — iCloud,
keychain access groups, StoreKit — behaves differently or not at all there. The
0.2.0 launch crash was exactly this: SwiftData quietly enabled CloudKit
mirroring because it saw the iCloud entitlement, which a simulator never
triggers.

```bash
cd ios
xcodebuild -project MyNote.xcodeproj -scheme MyNote -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/mynote-dev \
  -allowProvisioningUpdates build

DEV=$(xcrun devicectl list devices | grep -i iphone | awk '{print $(NF-1)}')
xcrun devicectl device install app --device "$DEV" \
  /tmp/mynote-dev/Build/Products/Release-iphoneos/MyNote.app
xcrun devicectl device process launch --device "$DEV" --console \
  --terminate-existing com.chrisphua.MyNote
```

`--console` streams the app's output, so a launch failure names itself instead
of arriving later as a symbolicated crash report.

## Verifying a real backup

The most useful manual test, and the one worth doing before every release:

1. Connect Google Drive on device A. Write a note.
2. Open Drive in a browser. There should be a `MyNote` folder containing
   `device-<id>.json`. **Open it** — it is readable JSON, and the note should be
   in it.
3. Connect the same Drive on device B (ideally the other platform). The note
   should appear.
4. Edit the same block on both devices while B is in airplane mode. Reconnect.
   The newer edit wins and neither device loses anything else.

## Rollback

There is no backend, so rollback is App Store / Play only: expire the TestFlight
build, reject the submission, or halt the staged rollout.

Which is why the **file format** matters more than it would with a server: a
client one version behind must keep reading what a newer one writes. `format` is
checked on read, unknown fields are ignored, and the version is only bumped for
a genuinely breaking change.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Drive option missing | No OAuth client id in the build. Expected on a fresh clone. |
| "Reconnect Google Drive" | Access revoked in the user's Google account, or the consent screen is still in testing mode with the user not on the test list. |
| iCloud option missing or failing | The user is signed out of iCloud, or iCloud Drive is off for the app. |
| Notes not appearing on the other device | They chose iCloud on one and Drive on the other — the two do not meet. Check the storage picker on both. |
| `403 insufficient scope` | The OAuth client was created for the wrong bundle id / package, or the scope was changed. |
| iOS build cannot find the Xcode project | It is generated, not committed. Run `xcodegen generate`. |
| App crashes instantly on device but is fine in a simulator | Almost certainly entitlement-related. Attach `--console` (above) and read the first error. If it mentions CloudKit, a `ModelConfiguration` is missing `cloudKitDatabase: .none`. |
