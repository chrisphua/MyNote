# Backup format

What MyNote writes into your Google Drive or iCloud Drive, and how two devices
agree on what your notes say.

This is a plain, inspectable format on purpose. If MyNote disappears tomorrow,
your notes are still sitting in your own Drive as readable JSON.

## What lands in the folder

```
MyNote/
  device-a1b2c3d4.json     written only by that device
  device-9f8e7d6c.json     written only by that device
  license.json             proof of purchase, if you bought Pro
```

One file per device. **A device writes its own file and never touches another's**
— which is the whole reason this works without a server. There is no file two
devices can both write, so there is no write conflict to resolve, nothing to
lock, and no coordinator to elect.

## A device file

```jsonc
{
  "format": 1,
  "deviceId": "a1b2c3d4",
  "updatedAt": 1789600000000,
  "changes": [
    {
      "entity": "block",
      "id": "8f3c…",
      "hlc": "0000018f5a2b3c4d-0000-a1b2c3d4",
      "deleted": false,
      "fields": {
        "note_id": "n-1",
        "order_key": "a0V",
        "type": "paragraph",
        "content": "{\"text\":\"Hello\"}"
      }
    }
  ]
}
```

`changes` holds **every record whose newest known version was written by this
device** — not a log, and not everything the user has. A record edited five
times appears once, at its latest version.

`content` and `spec` are JSON *strings*, not nested objects: they are stored
verbatim and only checked for parseability, so a newer app can add fields
without an older one choking.

## Who writes which record

A record's HLC carries the device that wrote it in its `node` field, so
authorship needs no separate column:

```
0000018f5a2b3c4d-0000-a1b2c3d4
|--- millis ---| |ctr| |-device-|
```

When device B edits a record device A created, the record's clock now names B,
so it moves into B's file and drops out of A's on their next backups. Ownership
transfers itself.

## Merging

On sync, a device lists the folder, downloads every file it has not already
merged, and applies each change with one rule:

> **A change is applied only if its clock is strictly newer than the local copy.**

Last-write-wins, per record, by hybrid logical clock.

Wall time alone would be unusable: two phones with clocks three seconds apart
would silently reorder each other's edits. The HLC keeps wall time so ordering
stays human-meaningful, adds a counter to break ties within a millisecond, and
guarantees a device's own edits are strictly increasing even when its clock
jumps backwards after an NTP correction.

**This is implemented twice — Swift and Kotlin — and the encodings must match
byte for byte.** Shared vectors are asserted in both suites. A change to padding
or field order in one place silently corrupts merging everywhere.

## Skipping unchanged files

Each provider gives a change marker — Drive a `version`, iCloud modification
time plus size. A device records the marker it last merged for each file and
skips files that have not moved.

Without this, every sync would download every other device's entire backup. On a
metered connection that is the difference between a usable app and an uninstall.

## Ordering

Notes and blocks order by a string key, not an integer position. Inserting
between two neighbours generates a key strictly between them, so an insert
rewrites exactly one row and two offline devices inserting at the same spot
interleave rather than collide.

Alphabet is `0-9A-Za-z` (base 62), compared lexicographically.

> **Invariant: a generated key never ends in `'0'`.**
>
> Nothing sorts below `"0"` — `"00"` sorts *after* it — so `between(null, "0")`
> has no answer. An early version looped forever building `"000000…"`, and the
> front-insert test hung for fourteen minutes before it was caught. Keeping the
> last digit non-zero guarantees there is always room below any existing key.

## Deletes

Tombstones, never hard deletes, or a device that was offline would never learn
the record is gone. A deleted record syncs as `{"deleted": true, "fields": {}}`.

## Uploading

A device rewrites its own file whenever its records have moved on since the last
successful upload — tracked by comparing the newest clock it has authored
against the clock at the time of the last write.

The local database is the source of truth and the file is a projection of it, so
a failed upload cannot lose an edit. It only means the folder is briefly behind,
and the next attempt rewrites it from scratch.

## Forward compatibility

`format` is checked on read. Unknown *fields* are ignored, so a newer app may add
them freely. A newer *format* is refused with a message telling the user to
update, rather than being half-read into something wrong.

## What is not in the folder yet

- **Attachment bytes.** The record kind exists and syncs as metadata; the files
  themselves are not uploaded.
- **Compression.** Files are plain JSON. Readable, and larger than they need to be.
