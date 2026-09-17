# MyNote — working notes for Claude

Offline-first note app. **No backend.** Notes are backed up into the user's own
Google Drive or iCloud Drive. Native SwiftUI iOS app, native Compose Android app,
shared merge logic implemented once per platform.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing anything
structural, and [docs/BACKUP-FORMAT.md](docs/BACKUP-FORMAT.md) before touching
anything that is written to a folder.

## The two rules everything follows from

**1. An edit is saved locally and the user moves on.** Backing up is a background
consequence, never a step the user waits for.

**2. A device writes exactly one file and never another device's.** This is what
removes write conflicts without a server. Any change that makes one device write
into another's file breaks the core safety property of the design.

## Commands

```bash
# iOS
cd ios/MyNoteCore && swift test              # no simulator, <1s
cd ios && xcodegen generate                  # the .xcodeproj is generated, not committed
cd ios && xcodebuild -project MyNote.xcodeproj -scheme MyNote \
            -destination 'generic/platform=iOS Simulator' \
            CODE_SIGNING_ALLOWED=NO build

# Android
cd android && ./gradlew :core:test
cd android && ./gradlew :app:assembleDebug
```

Java 17 is required for Gradle. If the system default is Java 8:
`JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew …`

## Two implementations, one file format

`Hlc`, `FractionalIndex`, `DeviceFile` and `License` exist in **Swift and
Kotlin**, and their encodings must match byte for byte — both apps read the same
files out of the same Drive folder.

**Changing one means changing both, plus the shared test vectors in each suite.**
There is no build-time check; the vectors are the only guard.

| Concept | Swift | Kotlin |
|---|---|---|
| Clock | `HybridLogicalClock.swift` | `Hlc.kt` |
| Ordering | `FractionalIndex.swift` | `FractionalIndex.kt` |
| File format | `RemoteFolder.swift` (`DeviceFile`) | `RemoteFolder.kt` (`DeviceFile`) |
| Merge loop | `FolderSync.swift` | `FolderSync.kt` |
| Purchase hand-off | `License.swift` | `License.kt` |
| Theme model | `ThemeSpec.swift` | `ThemeSpec.kt` |

## Traps that have already caused bugs

- **An order key must never end in `'0'`.** Nothing sorts below `"0"`, so
  `between(null, "0")` has no answer. This once looped forever and hung the test
  suite for fourteen minutes.
- **Authorship comes from the clock's `node`, not a column the app sets.** Filter
  on it to find what this device owns. Anything that writes `authorNode`
  independently of `hlc` will put records in the wrong file.
- **Local records carry no account.** Anything that changes the connected folder
  must wipe the local database first, or one person's notes get uploaded into
  another's Drive.
- **Never skip the provider version check.** Re-downloading every device file on
  every sync is the difference between a usable app and an uninstall on a
  metered connection.
- **Free users may read a folder but not write to it.** That is not an oversight
  — it is how a purchase made on the other platform is discovered.
- **iCloud Drive cannot reach Android.** Do not write copy, tests or docs that
  imply otherwise.
- **Swift 6:** a nonisolated `deinit` cannot touch `@MainActor` state, and a
  `ModelContext` belongs to exactly one actor.

## Conventions

- Field names inside `fields` are the wire format's own (`note_id`, `order_key`).
  No translation layer on either client.
- `content` and `spec` are JSON **strings** on the wire, not nested objects.
- Adding a syncable field → add it to both platforms' model *and* wire
  conversion, and leave `format` alone unless it is genuinely breaking.
- `format` is checked on read; unknown fields are ignored. A client one version
  behind must keep working, because there is no server to coordinate a rollout.
- Never commit an OAuth client id, `.p8`, or a keystore. Both apps build and run
  without any of them — that is intentional, and it is how CI builds PRs.

## After finishing a feature

Run the code reviewer before opening a PR:

```
Use the code-reviewer agent to review my changes.
```

It is defined in `.claude/agents/code-reviewer.md`. The same review runs
automatically on every PR via `.github/workflows/code-review.yml`.

Then update [CHANGELOG.md](CHANGELOG.md) — user-visible changes, not commit
summaries.
