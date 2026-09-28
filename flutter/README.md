# Flutter port

One codebase for both platforms. Being built alongside the native apps, not in
place of them: iOS 1.0.0 (11) is on TestFlight and Android 1.0.0 (5) is the
closed-testing draft, and those keep shipping while this grows.

## Why

Not deployment — that is unchanged. The same keystore, the same App Store
Connect key, the same two stores, the same upload scripts. What this removes is
the tax written down in `CLAUDE.md`:

> `Hlc`, `FractionalIndex`, `DeviceFile` and `License` exist in **Swift and
> Kotlin**, and their encodings must match byte for byte… There is no
> build-time check; the vectors are the only guard.

One implementation cannot drift from itself.

## Order of work

1. **`mynote_core`** — pure Dart, no Flutter dependency, no UI. *In progress.*
2. Storage — `drift`, replacing Room and SwiftData.
3. Sync — `FolderSync` and Drive via `googleapis`. iCloud needs a Swift
   platform channel, so it is the one part that stays two implementations.
4. Editor — where `super_editor` or `appflowy_editor` earns its keep.
5. Billing — `in_app_purchase`, collapsing StoreKit and Play Billing into one.

## The rule this port lives under

Every core type is ported against **the vectors the native suites already
assert**, not against a reading of the code. A Dart type that disagrees with
Swift and Kotlin would put a device's notes in the wrong order, or pick the
wrong winner in a merge, in a folder shared with apps already installed.

```bash
cd flutter/mynote_core && dart test      # no simulator, under a second
```

## Ported so far

| Type | Dart | Vectors shared with |
|---|---|---|
| `Hlc` | `lib/src/hlc.dart` | `HlcTest.kt`, `HybridLogicalClockTests` |
| `FractionalIndex` | `lib/src/fractional_index.dart` | `FractionalIndexTest.kt` and its Swift twin |
