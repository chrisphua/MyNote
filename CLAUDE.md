# MyNote — working notes for Claude

Offline-first note app. Cloudflare Worker backend, native SwiftUI iOS app, native
Compose Android app. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before
changing anything structural.

## The rule everything else follows from

**An edit is saved locally and the user moves on.** Sync is a background
consequence of editing, never a step the user waits for.

Its corollary, and the most important invariant in the codebase:
**a local edit leaves the outbox only after the server confirms it.**

## Commands

```bash
# Backend
cd backend && npm test && npm run typecheck
cd backend && npm run dev                    # local D1 + R2, no account needed

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

## Three implementations, one protocol

`Hlc` and `FractionalIndex` exist in TypeScript, Swift **and** Kotlin, and their
encodings must match byte for byte — the server compares clocks with a plain SQL
`>`.

**Changing one means changing all three, plus the shared test vectors in each
suite.** There is no build-time check for this; the vectors are the only guard.

| Concept | TypeScript | Swift | Kotlin |
|---|---|---|---|
| Clock | `backend/src/hlc.ts` | `HybridLogicalClock.swift` | `Hlc.kt` |
| Ordering | — | `FractionalIndex.swift` | `FractionalIndex.kt` |
| Sync loop | `backend/src/sync.ts` | `SyncEngine.swift` | `SyncEngine.kt` |
| Theme model | — | `ThemeSpec.swift` | `ThemeSpec.kt` |

## Traps that have already caused bugs

- **Never remove an outbox entry by record id alone.** The outbox collapses a
  burst of typing onto one row, so a keystroke landing while a push is in flight
  rewrites the row being confirmed. Delete by `(key, hlc)` or that edit is lost
  unsent — this is the single most expensive bug the project has had.
- **Local rows carry no `uid`.** Anything that changes the signed-in account must
  wipe the local database first, or one account's notes are pushed into another.
- **An order key must never end in `'0'`.** Nothing sorts below `"0"`, so
  `between(null, "0")` has no answer. This once looped forever and hung the test
  suite for fourteen minutes.
- **SQLite checks `NOT NULL` before `ON CONFLICT`.** A tombstone for a record the
  server has never seen needs its own statement with placeholder values.
- **Every query filters on `uid`** — including the `WHERE` of an upsert's conflict
  clause. Without it one account can overwrite another's row by guessing an id.
- **Play auto-refunds unacknowledged purchases after three days.** Always
  acknowledge.
- **Entitlements key on `uid` alone.** Adding a platform column to the read path
  would quietly break cross-platform unlocking.
- **Swift 6:** a nonisolated `deinit` cannot touch `@MainActor` state, and a
  `ModelContext` belongs to exactly one actor.

## Conventions

- Wire field names are the server's column names (`note_id`, `order_key`). No
  translation layer on either client.
- `content` and `spec` are JSON **strings** on the wire, not nested objects.
- Backend: no npm dependency where WebCrypto will do. Cold starts are the budget.
- New syncable field → add it to the migration, `TABLES` in `schema.ts`, and both
  clients' model plus wire conversion.
- Migrations are **additive only**. They run before the Worker that reads them,
  and a client one version behind must keep working.
- Never commit `GoogleService-Info.plist`, `google-services.json`, `.p8`, or a
  keystore. Both apps run local-only without them — that is intentional, and it
  is how CI builds pull requests.

## After finishing a feature

Run the code reviewer before opening a PR:

```
Use the code-reviewer agent to review my changes.
```

It is defined in `.claude/agents/code-reviewer.md` and focuses on the four areas
where a bug is data loss, lost revenue, or a security hole: sync durability,
clock/ordering correctness, entitlements, and tenant isolation. The same review
runs automatically on every PR via `.github/workflows/code-review.yml`.

Then update [CHANGELOG.md](CHANGELOG.md) — user-visible changes, not commit
summaries.
