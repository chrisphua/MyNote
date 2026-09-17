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
   - **iOS** — bundle id `io.mynote.app`
   - **Android** — package `io.mynote.app` plus your signing certificate SHA-1
   - **Web** — needed as the `serverClientId` for Android's offline access

> **`drive.file` needs no security assessment.** It grants per-file access to
> files the app created. Requesting `drive` or `drive.readonly` instead would
> put you into Google's restricted-scope review, which is slow and expensive.
> Do not widen the scope.

**Publish the consent screen** before release, or sign-in is capped at 100 test
users.

### 2. Apple — iCloud and the store

1. Register the bundle id `io.mynote.app` with **iCloud** (CloudKit/Documents)
   and **In-App Purchase** capabilities.
2. Create the iCloud container `iCloud.io.mynote.app`.
3. Create the in-app purchase `io.mynote.pro`, non-consumable, $14.99.
4. **Enrol in the Small Business Program.** 15% instead of 30%. Do this before
   your first sale.
5. Create an **App Store Connect API key** (Users and Access → Integrations),
   role *App Manager*. Keep the `.p8`; it downloads once.

### 3. Play Console

1. Create the app with package `io.mynote.app`.
2. Create the in-app product `io.mynote.pro`, one-time, $14.99.
3. Create a **service account** with the *Android Publisher* role for CI
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
| `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION` | fastlane match certificate repo |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i release.jks` |
| `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | your keystore |
| `PLAY_SERVICE_ACCOUNT_JSON` | the service account JSON, verbatim |

Create two **environments**, `ios-release` and `android-release`, and add a
required reviewer to each so a store submission is always a deliberate act.

### 5. Signing certificates (iOS)

```bash
cd ios
bundle install
bundle exec fastlane match appstore
```

`match` keeps certificates in a private git repo so CI and your laptop use the
same ones.

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
