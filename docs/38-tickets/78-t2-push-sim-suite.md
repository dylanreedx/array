# 78 — T2 simulator push suite (`scripts/push-sim-test.sh`)

> **RULING C-20260706-030 (night-3 orchestrator pre-flight, 2026-07-06) — this doc IS the ticket.**
> B9 has no prior numbered ticket; the contract is _COMPANION_SPEC.md §4 tier T2 plus this ruling.
> Bindings (supersede the spec text where they conflict):
>
> 1. **Bundle id is `dev.dylanreedx.continuum`.** Spec §4's `dev.dylanreed.continuum` is STALE —
>    the bundle was renamed in 335a99a (App ID collision). Everywhere the script targets the app
>    (simctl push / install / launch / get_app_container) it uses the renamed id. (The desktop
>    sender's `apns-topic` value is out of scope for this ticket — T3/device territory.)
> 2. **Payload source of truth = the landed builders.** The script must NOT contain hand-written
>    payload JSON. A new app flag `--push-payload-dump <dir>` writes `N1.apns` … `N8.apns` as the
>    EXACT `encodedJSON()` bytes of `PushPayloadBuilder.fixturePayload(for:)` for each
>    `PushCategory.allCases` member (the same fixtures the Push Smoke lab card renders). No
>    `"Simulator Target Bundle"` key is injected — the bytes stay byte-identical to production
>    payloads; the bundle id is passed to `simctl push` as the CLI argument instead.
> 3. **Matrix wiring is additive.** A sibling flag `--push-payload-dump-check` dumps to an internal
>    `mktemp -d`, validates, cleans up, and exits 0/1; `scripts/run-matrix.sh` gains ONE
>    `run_app_check .build/debug/continuum-revived --push-payload-dump-check` line (never weaken
>    anything else). Validation = 8 files named `N1.apns`–`N8.apns` exist, each parses as JSON,
>    each file's `aps.category` equals the corresponding `PushCategory.identifier`, each ≤ 4096
>    bytes. Do NOT re-duplicate the full T1 literal spec map — payload correctness is already
>    matrix-gated by APNSPushServiceTests; this check only proves the on-disk dump is the real
>    payload set.
> 4. **Honesty about what T2 can verify headless.** `simctl push` exit 0 means the payload was
>    accepted and delivered to the simulator — NOT that a banner rendered. Banner rendering,
>    lock-screen actions, category-settings suppression, and deep-link routing are VISUAL legs:
>    the script prints an explicit "visual confirmation owed" note, and the ledger row tags
>    `visual-gate-owed` (morning checklist, screenshots into the morning report). Notification
>    authorization needs a one-time Allow tap in the simulator on first launch — the script prints
>    this instruction; it must never claim rendering verified.
> 5. **ComponentLab: EXEMPT.** No new user-visible surface or reusable component ships here (a
>    shell script + a T3-style tool flag). The N1–N8 payloads already have the "Push Smoke" lab
>    card from ticket 63; reviewers should not demand a new card.
> 6. **`--push-test` (real-APNS T3 flag) is untouched.** This is a separate, simulator-only tool.

## What it is

Spec §4 tier **T2**: a script `scripts/push-sim-test.sh` that fires all 8 push categories at the
iOS companion app in the simulator via `xcrun simctl push`, so banner rendering / actions /
category settings / deep-link routing can be confirmed without real APNS. Screenshots feed the
morning report.

## Deliverables

### 1. App flag `--push-payload-dump <dir>` (+ `--push-payload-dump-check`)

In `ContinuumApp.main()` alongside `--push-test` (runs and exits before any UI):

- `--push-payload-dump <dir>`: for each `PushCategory.allCases` in declaration order, write
  `<dir>/<rawValue>.apns` containing exactly `try PushPayloadBuilder.fixturePayload(for: category).encodedJSON()`.
  Creates `<dir>` if needed. Missing/empty dir argument → usage line on stderr, exit 2. Prints one
  line per file written. Exit 0 on success, 1 on any throw.
- `--push-payload-dump-check`: dump into a fresh `mktemp -d`, run the ruling-3 validation
  (8 files, JSON-parseable, `aps.category` == `identifier` per category, ≤ 4096 bytes each),
  print measured values, remove the temp dir, exit 0/1. Wire into `scripts/run-matrix.sh` as one
  additional `run_app_check` line next to the other app-flag checks.

### 2. `scripts/push-sim-test.sh`

`bash`, `set -euo pipefail`, executable. Usage:

```
scripts/push-sim-test.sh [--device <name|udid>] [--out <dir>] [--delay <seconds>] [--no-screenshots] [--no-install]
```

Behavior, in order:

1. **Payloads:** ensure `.build/debug/continuum-revived` exists (`swift build` if not), then dump
   the 8 payloads via `--push-payload-dump` into `$OUT/payloads/` (default `$OUT` =
   `mktemp -d`-style path under `/tmp`, printed at start and end).
2. **Simulator:** use `--device` if given; else the first booted device from
   `xcrun simctl list devices booted`; else boot the newest available iPhone (`simctl boot` +
   `simctl bootstatus -b`). Print the chosen udid/name.
3. **App install:** if the app is not installed (`simctl get_app_container <udid>
   dev.dylanreedx.continuum` fails) and `--no-install` was not passed: `cd ios && xcodegen
   generate && xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination
   "id=<udid>" -derivedDataPath <tmp> build`, then `simctl install` the built `.app`. With
   `--no-install` and no installed app → clear error, exit 1.
4. **Launch:** `simctl launch <udid> dev.dylanreedx.continuum` (ignore already-running failure);
   print the one-time notification-permission Allow-tap note (ruling 4).
5. **Fire:** for `N1`…`N8` in order: `xcrun simctl push <udid> dev.dylanreedx.continuum
   $OUT/payloads/N<i>.apns`; sleep `--delay` (default 2); unless `--no-screenshots`,
   `xcrun simctl io <udid> screenshot $OUT/shots/N<i>.png`. Print a per-category status line
   (`push accepted` / `push FAILED`).
6. **Summary:** print sent/failed counts, the out dir, and the ruling-4 honesty note (rendering
   and actions are the morning visual gate). Exit non-zero if any push command failed.

No hand-written payload JSON anywhere in the script (grep gate for reviewers: the only payload
bytes come from the dump flag).

## Done when

1. `swift build` clean; `CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh` green including
   the new `--push-payload-dump-check` line.
2. `scripts/push-sim-test.sh` exists, is executable, and implements the behavior above.
3. One honest end-to-end scripted run is ATTEMPTED headless (boot sim → install → launch → 8
   pushes → screenshots) and its real result recorded in the implementer notes: pushes
   accepted + screenshots captured is the target; if the sandbox blocks CoreSimulator, record
   precisely what failed and how far it got — do NOT fake it, the morning pass re-runs it.
4. `ios/` untouched (expected — categories/registration landed in 63); if it does get touched,
   the iOS sim-build gate applies.
5. Ledger row tags `visual-gate-owed` (banners/actions/settings/deep-links + screenshot review).
