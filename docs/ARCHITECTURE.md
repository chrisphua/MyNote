# Architecture

## The two rules

**1. An edit is saved locally and the user moves on.** Backing up is a background
consequence of editing, never a step the user waits for. A device with no
storage connected and no network is a fully working app.

**2. Each device writes exactly one file, and never another device's.** This is
what makes concurrent editing safe without a server: there is no file two
devices can both write, so there is no write conflict, no locking, and no
coordinator. Merging happens on read.

## Pieces and what each one owns

```
┌──────────────────────────┐        ┌──────────────────────────┐
│  iOS  (SwiftUI)          │        │  Android  (Compose)      │
│  ├─ SwiftData ───────────┤        │  ├─ Room ────────────────┤
│  ├─ MyNoteCore           │        │  ├─ :core                │
│  │   Hlc · FractionalIndex · FolderSync · DeviceFile · ThemeSpec │
│  ├─ StoreKit 2           │        │  ├─ Play Billing 7       │
│  ├─ iCloudDriveFolder    │        │  └─ GoogleDriveFolder    │
│  └─ GoogleDriveFolder    │        │                          │
└───────────┬──────────────┘        └───────────┬──────────────┘
            │                                   │
            ▼                                   ▼
   ┌─────────────────┐              ┌─────────────────────────┐
   │  iCloud Drive   │              │   Google Drive          │
   │  (Apple only)   │              │   MyNote/               │
   └─────────────────┘              │     device-<id>.json    │
                                    │     license.json        │
                                    └─────────────────────────┘
```

| Component | Owns | Deliberately does not own |
|---|---|---|
| `MyNoteCore` / `:core` | Clocks, ordering, the file format, the merge loop, the theme model | Persistence, UI, platform SDKs, any provider detail |
| `RemoteFolder` implementations | Four methods: list, read, write, delete | Anything about merging |
| Platform apps | Persistence, rendering, purchasing, provider auth | Merge rules — those live in core, once per platform |

**Why the engine is a separate module on both platforms:** it makes the part
that is expensive to get wrong testable in milliseconds, with no simulator, no
emulator and no network. All 92 tests run that way.

**Why `RemoteFolder` is four methods:** adding Dropbox or OneDrive later is an
afternoon, with no new sync logic and no new tests for merge behaviour.

## Data model

Four record kinds — `note`, `block`, `theme`, `attachment` — each carrying:

- `hlc` — hybrid logical clock; decides who wins a conflict, and its `node`
  field records **which device wrote it**
- `deleted` — a tombstone, never a hard delete, so a device that was offline
  still learns the record is gone

Notes nest (like Notion pages) and blocks nest within a note. Both order by a
**fractional index**: a string strictly between its neighbours, so an insert
rewrites one row and two devices inserting at the same spot interleave.

See [BACKUP-FORMAT.md](BACKUP-FORMAT.md) for what this looks like on disk.

## Decisions worth knowing about

**No server.** The earlier design had a Cloudflare Worker with its own database.
It worked, and it was cheap, but it made us the custodian of other people's
notes and put a bill between the app and its users. Removing it deleted an
entire backend, all authentication, quota enforcement, rate limiting, receipt
verification, and every secret in the project.

**Authorship comes from the clock, not a column.** A record's HLC already names
the device that wrote it, so "everything this device owns" is a filter on the
clock. When another device edits a record, it moves into *their* file
automatically and drops out of ours — no bookkeeping, no ownership transfer
protocol.

**The local database is the source of truth; the file is a projection.** This is
strictly stronger than the outbox it replaced. A failed upload delays a backup,
it cannot lose an edit, because nothing is ever dequeued — the next sync simply
rewrites the file from the database.

**Skip unchanged files by provider version.** Drive gives a `version`; iCloud
gives modification time and size. Without this, every sync would download every
other device's entire backup, which on a metered connection is the difference
between a usable app and an uninstall.

**Hybrid logical clocks over plain timestamps.** Two phones with clocks three
seconds apart would silently reorder each other's edits. An HLC keeps wall time
so ordering stays human-meaningful, but adds a counter that breaks ties and
guarantees a device's own edits are strictly increasing even if its clock jumps
backwards.

**Last-write-wins per block, not a text CRDT.** A full CRDT would give
character-level merge at the cost of a large dependency, much more storage per
block, and a great deal of complexity. Per-block LWW means two people editing
different paragraphs merge cleanly and two editing the same paragraph lose one
version — an acceptable trade for a personal note app, and revisitable without
changing the file format.

**Purchases travel in the folder.** With no server there is nowhere neutral to
record that someone paid, so `license.json` sits beside the notes. Each platform
verifies its own store receipt strongly; the file is the weaker cross-platform
path. See [MONETIZATION.md](MONETIZATION.md) for the threat model, stated plainly.

**Free users can read but not write.** Connecting a folder without Pro merges
what is there and uploads nothing. That is what lets someone install on a second
platform, connect their Drive, and have the licence they already bought unlock
the app.

## Security and privacy

| Concern | Where it lands |
|---|---|
| Who can read the notes | Only the user. They are in that user's own Drive or iCloud, under that provider's account security. |
| What we can read | Nothing. There is no server and no telemetry. |
| Scope requested from Google | `drive.file` — per-file access to files this app created. Not `drive`, not `drive.readonly`; those are restricted scopes needing a security assessment, and we have no business reading anything else. |
| Where the Drive refresh token lives | iOS Keychain, `kSecAttrAccessibleAfterFirstUnlock`. On Android, Google's authorization client holds it. |
| Switching storage | Wipes local records first, with a confirmation naming what will be lost. Records carry no account, so keeping them would upload one person's notes into another's Drive. |
| Theme input | `sanitized()` on both platforms before anything reaches a renderer — a theme arrives from another device and is arbitrary input. |

## Known gaps

Honest list of what is not built yet.

- **Attachments are not uploaded.** The record kind exists and syncs as
  metadata; the bytes are not yet written to the folder.
- **Whole-file uploads.** A device rewrites its entire file when anything
  changes. Fine for thousands of blocks; a user with tens of thousands on a
  metered connection would notice. Chunking or compression is the fix.
- **No backup pruning.** A device file keeps a record until another device takes
  it over. Files from a device the user no longer owns are never cleaned up.
- **No conflict UI.** Last-write-wins is applied silently; the loser is not
  offered for review.
- **No E2E encryption beyond the provider's.** Google and Apple can read the
  files, as they can any file in their storage.
- **Numbered lists always render "1."** Real numbering needs sibling indices.
- **No iOS UI tests / Android instrumentation tests.** Logic is well covered;
  the view layers are not.
