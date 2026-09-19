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

**Anything touching entitlements must be tested on a real device.** A simulator
does not apply them, so a whole class of launch failure is invisible there —
see the CloudKit trap below.

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
- **Compose: `adjustResize` does nothing under `enableEdgeToEdge()`.** The window
  stops being resized for the keyboard, so anything anchored to the bottom —
  a `Scaffold`'s `bottomBar` — is simply drawn underneath it. The formatting bar
  shipped invisible this way, and the manifest looked correct the whole time.
  Hold the screen above the IME explicitly:
  `Modifier.windowInsetsPadding(WindowInsets.ime.union(WindowInsets.navigationBars).only(WindowInsetsSides.Bottom))`.
- **A control that acts on the focused field must not vanish when focus
  leaves.** Pressing a button in the formatting bar moves focus off the text, and
  clearing the bar's state on focus-loss removed the bar between the press and
  the release — so the press never became a click. Keep the last edited block,
  and clear it on Done.
- **A field that owns its text while focused cannot be handed new text through
  the store.** The guard has to be ownership, not "is this different from what I
  last wrote": every keystroke is its own write, the echoes arrive behind the
  typing, and adopting a stale one rewinds the field — typing "first" came back
  as "fir". So a merge, which replaces the text of a block that is about to take
  focus, carries its text in the caret request instead of waiting for the store.
- **A block that renders no text field must never be a caret target.** A
  divider is the one we have. Folding a block into it puts the words where the
  writer can never reach them again — and they still sync — while asking it for
  the caret throws `FocusRequester is not initialized` and takes the app down.
  The welcome note has a divider in the middle, so this was reachable on the
  first note every new user opens. Pick the merge or delete target with
  `holdsText` / `textBlock(above:)`, on **both** platforms.
- **A block is written whole, so never build a write on a composition
  snapshot.** `asChange()` sends every field including `content`. A snapshot the
  screen captured a frame ago still holds the text from before the last
  keystroke, so a "change the type" write built on it puts the older text back
  under a newer clock and the character is gone, locally and in the backup.
  Re-read the row inside the coroutine (`setBlockType`, `blockById`); launches on
  one dispatcher run in order, so the keystroke has landed by then.
- **Anything bound straight to the store fights the person typing.** Every
  field needs a local copy it owns while focused, adopting the store's value
  only when focus leaves. The title was missed when the blocks were fixed, and
  behaved exactly as the blocks used to: the caret jumped to the end on every
  keystroke.
- **A block's text view does not scroll, so its cost is its length.** Measuring
  it lays out every line. One block holding a pasted article made a single
  keypress take most of a second on a Mac, and far worse on a phone. A
  multi-paragraph paste is therefore split into blocks, the block stack is
  lazy, and writes are coalesced rather than made per keystroke.
- **A lazy stack cannot give focus to a row it has not built.** True of
  `LazyVStack` and `LazyColumn` alike: a split near the end of a long note
  focuses nothing and types into the block above. Whatever aims the caret has
  to scroll the target into view first. Both platforms now do.
- **`uiautomator dump` only covers the app's own window.** A Compose
  `DropdownMenu` is a separate window and never appears in the dump, which reads
  exactly like a button that does not respond. Take a screenshot before
  concluding a tap was lost.
- **SwiftData turns CloudKit mirroring on by itself.** `ModelConfiguration`
  defaults to `cloudKitDatabase: .automatic`, which enables mirroring the moment
  it finds an iCloud entitlement — and this app has one, for iCloud *Drive*
  documents. CloudKit then rejects our schema (it supports neither unique
  constraints nor non-optional attributes without defaults, and we use both),
  the store fails to load, and the app dies on launch. Always pass
  `cloudKitDatabase: .none`. **This cannot reproduce in a simulator**, where the
  entitlement has no effect — it only appears on a real device.

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
