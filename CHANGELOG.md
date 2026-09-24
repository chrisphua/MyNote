# Changelog

Notable changes to MyNote. Format follows [Keep a Changelog](https://keepachangelog.com/1.1.0/);
versions follow [SemVer](https://semver.org/). iOS and Android ship from the same
version number so a bug report maps to one commit.

## [1.0.0] — 2026-09-21

The first release. Offline-first notes on iOS and Android, backed up into your
own iCloud Drive or Google Drive, with no server in between.

### Fixed

- **Android: the formatting bar was unreachable.** It sits at the bottom of the
  screen, and the window draws edge to edge — so the keyboard covered it. The
  controls were there the whole time, under the keys. The editor now holds
  itself above the keyboard.
- **Android: Return starts a new block** instead of putting a line break inside
  the current one, and typing carries on in the new block rather than the old.
- **Android: Backspace at the very start of a block** folds it into the one
  above, with the caret left where the two texts join — so the keystroke can be
  undone by typing. Backspacing out of the first block turns a heading, list or
  quote back into plain text.
- **Android: the formatting bar stays put while it is being used.** Pressing one
  of its buttons takes focus off the text, which used to take the bar off screen
  between the press and the release — so the press never became a click and the
  block's type never changed. Changing a type now also hands the caret back,
  rather than ending the sentence.
- **Android: a fresh install opens with the welcome note**, as on iOS.
- **iOS: the last thing you typed is never lost.** Saving had been coalesced
  into one write every 300ms to make a long note cheap to type in, with nothing
  forcing that out when the app was backgrounded or killed — so an edit made in
  the last fraction of a second never reached the store, and deleted words came
  back. Edits save as they are made again.
- **Android: the Backup section is hidden when there is nowhere to back up
  to.** Google Drive is the only destination an Android device has — iCloud
  cannot reach Android — so a build without a Drive client id was showing a
  Backup heading above a single row that chose nothing.
- **iOS: the caret matches the text it sits in.** A heading showed a caret
  sized for body text, because the text view's own font was never set — the
  caret takes its metrics from there, while the words were drawn from the
  block's attributed text.
- **iOS: block styles are a named menu, not ten icons.** Heading 1, 2 and 3
  were three sizes of the same glyph at 17pt, indistinguishable in a scrolling
  row. The bar now shows the current style by name and opens a list that names
  every option. Bold, italic, underline and strikethrough stay as buttons,
  because those are pressed mid-sentence.
- **Android: the ⋮ beside every block is gone.** Everything it held — every
  block type — is on the bar above the keyboard, which is where iOS has always
  had it.
- **Android: notes are deleted by swiping**, not by a bin sitting on every row.
- **The note list is just titles.** The page glyph beside every title is gone;
  it was the same icon on every row and said nothing about the note.
- **Inline formatting.** Bold, italic, underline, strikethrough and links can
  be applied to part of a line rather than to a whole block, from a bar above
  the keyboard that shows what the selection already carries. Formatting
  travels with the words: split a block and each half keeps its own, merge two
  and both survive.
- **iOS: pasting a large chunk of text no longer locks the editor up.** A paste
  of several paragraphs now becomes one block per paragraph, the way a block
  editor should, instead of burying an entire article in a single block whose
  text view had to lay every line of it out again on each keystroke. Typing
  into a long note is roughly seven times cheaper than it was.
- **iOS: a word can be inserted anywhere in a title.** The title was wired
  straight to the store, so every keystroke was written, read back and handed
  to the field again — which reset it and put the caret at the end. After
  pasting a title, text could only be added after the last character.
- **iPad: the note list is visible on launch.** In portrait the split view hid
  it, so a fresh install opened on an empty pane reading "Pick a note, or start
  a new one" with no list in sight. Showing the list also no longer slides it
  over the note you are reading.
- **Android: tapping into a note could undo an edit made on another device.**
  Moving the caret reports the same way an edit does, and the block was written
  back each time — under a fresh clock, so a device that had not synced yet
  would overwrite the newer text with its own older copy, on both devices and in
  the backup. Only an actual edit is written now.
- **Android: placing the caret after an existing line break no longer splits the
  block.** A pasted paragraph keeps its line breaks, and parking the caret after
  one was read as having just pressed Return.
- **Android: splitting a block keeps the last character typed.** The split was
  built from the copy on screen, which can be one keystroke behind the store.
- **Both: a block whose formatting cannot be read keeps its words.** Anything
  unreadable in the stored payload used to blank the whole block, and because a
  block is written whole the next keystroke wrote that blankness back — text
  gone, locally and in the backup. The text survives now and only the formatting
  is dropped. iOS also reads a run written without any marks, which Android has
  always been able to write.
- **Both: backspacing or deleting a block next to a divider no longer loses the
  text.** It folds into the nearest block that can actually hold text, rather
  than into the divider, where it would have been unreachable but still backed
  up. On Android the same mistake crashed the app outright — on the welcome note
  every new install is given.

## [0.2.0] — Serverless

**MyNote no longer has a backend.** Notes are backed up into storage the user
already owns, and nothing of theirs touches hardware we control.

### Changed

- **Removed the entire backend.** The Cloudflare Worker, D1 database, R2 bucket,
  Firebase Auth, all server secrets and the deploy pipeline are gone. So are
  accounts: MyNote has no concept of a user.
- **Backup goes to the user's own storage** — iCloud Drive (Apple devices) or
  Google Drive (iPhone, iPad *and* Android). The storage picker states plainly
  that Apple publishes no iCloud Drive API for Android, so anyone using both
  platforms needs Drive.
- **New backup format.** Each device writes exactly one JSON file and never
  another's, which removes write conflicts entirely — there is no file two
  devices can both write, so nothing to lock. Merging happens on read, by the
  same hybrid logical clock as before. The format is documented and readable:
  if MyNote disappears, the notes are still plain JSON in the user's Drive.
- **The outbox is gone.** The local database is the source of truth and the
  remote file is a projection of it, so a failed upload cannot lose an edit —
  it only means the folder is briefly behind. This is strictly stronger than
  the queue it replaces, and it structurally eliminates the in-flight-edit bug
  class fixed in 0.1.0.
- **Pricing is now one purchase: MyNote Pro, $14.99, paid once**, unlocking
  custom themes and cloud backup. The subscription is withdrawn: with no
  servers there is no recurring cost, and charging monthly for an expense that
  does not exist is not defensible. Running costs fell from ~$174/year to $114.
- **Purchases cross platforms through a `license.json` file** in the user's own
  folder rather than a server. Free users may connect a folder and read from it
  — that is what lets a purchase made on the other platform be discovered — but
  uploading requires Pro.
- **iOS now has zero third-party dependencies.** Google Drive is reached through
  its REST API with a hand-rolled PKCE flow; Firebase is gone. Android is down
  to four.
- Google access uses the `drive.file` scope only — per-file access to files the
  app created, which also avoids Google's restricted-scope security assessment.

### Removed

- Server-side sync, entitlement storage, quota enforcement, receipt
  verification, attachment hosting, store webhooks, and every secret that went
  with them.
- Sign-in. There is no account to create.

### Changed

- **Everything is free.** The paywall is switched off behind
  `AppFeatures.paidFeaturesEnabled`, so custom themes and cloud backup are
  unlocked for everyone, no purchase UI is shown, and neither StoreKit nor Play
  Billing is contacted at launch. Selling waits until the app is stable and
  published. The purchasing code is kept, not deleted — it works and is tested,
  and re-enabling it is one constant.

### Fixed

- **The app crashed on launch on a real device.** SwiftData defaults
  `ModelConfiguration` to `cloudKitDatabase: .automatic`, which enables CloudKit
  mirroring as soon as it finds an iCloud entitlement — and MyNote has one, for
  iCloud *Drive* documents. CloudKit rejects the schema, because it supports
  neither unique constraints nor non-optional attributes without defaults, and
  MyNote uses both. The store failed to load, the in-memory fallback failed for
  the same reason, and the app died. Mirroring is now switched off explicitly;
  MyNote does not use CloudKit at all. It could not reproduce in a simulator,
  where entitlements have no effect.

### Known gaps

Attachment bytes are not yet uploaded, device files are rewritten whole rather
than chunked, and backups from a device the user no longer owns are never
pruned. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## [0.1.0] — Server-backed (withdrawn)

### Added

- **Sync protocol** — cursor-based push/pull over a single monotonic sequence per
  user, with hybrid logical clocks for conflict resolution and fractional
  indexing for ordering. Implemented three times (TypeScript, Swift, Kotlin) with
  shared test vectors to keep the encodings identical.
- **Cloudflare Worker backend** — D1 for notes, blocks, themes and entitlements;
  R2 for attachments; Firebase ID token verification against Google's JWKS.
- **Offline-first iOS app** — SwiftUI block editor over SwiftData, with a durable
  outbox, adaptive one/two-pane layout, and StoreKit 2 purchasing.
- **Offline-first Android app** — Compose block editor over Room, same durable
  outbox, window-size-class layout, and Play Billing v7.
- **Fully customizable themes** — colours for light and dark, typography, spacing,
  corners and page width, live-previewed against real content and synced between
  devices. Three presets are free; building your own is a one-time purchase.
- **Cross-platform entitlements** — purchases are recorded against the Firebase
  `uid`, so buying on one platform unlocks the feature on the other. Apple and
  Google receipts are verified server-side by re-reading authoritative state from
  the store rather than trusting the client.
- **CI/CD** — GitHub Actions for backend (test → staging → production with a
  smoke test), iOS (core tests → build → TestFlight on tag) and Android (tests →
  debug build → Play internal on tag), plus an automated code review on every PR.
- **117 tests** — 35 backend (against real D1), 36 iOS core, 46 Android core.

*This release was never shipped; 0.2.0 replaced its architecture before launch.*

### Fixed

- **Fractional index could hang the editor.** `between(nil, "0")` looped forever,
  because nothing sorts below `"0"` — `"00"` sorts *after* it. Generated keys now
  never end in the lowest digit, which guarantees room below any existing key.
  Caught by a 300-iteration front-insert test that hung for 14 minutes.
- **Tombstones violated a NOT NULL constraint.** Deleting a record the server had
  never seen failed, because SQLite validates NOT NULL on the proposed row before
  resolving `ON CONFLICT`. Deletes now use their own statement with placeholder
  values, and preserve existing content server-side for restore.
- **Play webhooks resolved the wrong account.** A notification was matched to any
  user holding that product id. Purchase tokens are now stored on `iap_links` and
  looked up directly.

Found by the code-review agent before first release:

- **An edit made while a push was in flight was lost.** The outbox collapses a
  burst of typing onto one row per record, and entries were removed by record id
  — so a keystroke landing during the round trip overwrote the row that was then
  deleted as "confirmed". The edit was never sent, the UI reported "synced", and
  it was gone on reinstall. Removal is now by `(key, hlc)`, so a row rewritten in
  flight survives and goes out on the next pass.
- **iOS purchases never reached the server.** `PurchaseManager.configure` was
  defined but never called, so no entitlement row was ever written for an Apple
  buyer: sync returned `402` forever to someone who had paid. Neither client
  fetched `/v1/entitlements` either, so cross-platform unlocking did not work in
  either direction. Both are now wired at launch and on every auth change.
- **Switching accounts leaked notes between them.** Sign-out cleared only the
  Firebase session. Local rows carry no `uid`, so the previous account's queued
  edits were pushed into the next account, and the new account inherited a cursor
  that hid its own server records. Local data is now wiped when the signed-in
  account changes.
- **The sync cursor could skip a page.** Sequence numbers are allocated before
  the rows commit, so a device pulling an empty page in that window adopted a
  cursor covering rows it had not seen. An empty page now holds the cursor where
  the client had it.
- **A cross-account id collision silently dropped a note.** `id` was a global
  primary key, so a second account writing the same id resolved to a no-op that
  the client still treated as accepted. The key is now `(uid, id)`.
- **Apple transactions were claimable by whoever sent them first.** Transaction
  ids are numeric and guessable, and `/v1/iap/apple/verify` granted to the
  caller. Purchases now carry an `appAccountToken` derived from the Firebase uid,
  which the server verifies.
- **Hybrid logical clocks restarted from wall time on every launch**, so a
  backwards system-clock change made new edits sort below the server's copy and
  be silently discarded. The clock now resumes above the newest local edit.
- **Counter overflow was unhandled when merging a peer's clock** — Swift wrapped
  to zero (moving the clock backwards), TypeScript and Kotlin widened the encoded
  field from four hex digits to five, breaking the fixed-width ordering the
  server's `>` depends on. All three now carry into millis, as `tick` did.
- **Android queued the record and its outbox entry in separate transactions**, so
  process death between them left an edit that would never sync. Both writes are
  now one transaction, and repeated edits keep their place in the queue instead
  of moving to the back.
- **Themes synced but never appeared.** Rows were stored and never read back into
  the theme picker on either platform.
- **The claimed cross-platform clock test vectors did not exist** in TypeScript or
  Swift, leaving the encodings unguarded. All three suites now assert them.
- Malformed `order_key` values are rejected at the API boundary rather than
  corrupting ordering for every client.
