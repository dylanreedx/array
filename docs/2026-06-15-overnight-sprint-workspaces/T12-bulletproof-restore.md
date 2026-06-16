# T12 — Bulletproof restore: debounced atomic autosave + crash-safe reload

Status: todo
Tag: overnight
Depends on: T01, T02 · Blocks: T13, T14

## Goal
The live workspace layout (tiles, zones, sizes, viewport, z-order, last-active zone)
auto-persists so a quit / reboot / crash never loses it. Rapid mutations coalesce into a
single atomic write; the write survives a crash *mid-rename* (durable temp → fsync →
atomic rename); and on load, a corrupt/truncated primary `canvas.json` transparently
restores from the last-good backup with no half-written document ever loaded. This is the
persistence floor T13 (session resume) and T14 (profiles) build on.

## ⚠ Reality vs. the brief — read before scoping
Most of the brief's "build this" already exists. Confirmed by reading the real source:

- **`AtomicWriter`** (`Sources/ContinuumRevivedCore/AtomicWriter.swift`) ALREADY:
  encodes, **validates the bytes round-trip into `T` before touching disk**
  (`write`, lines 29–30), **backs up the existing file** before overwrite
  (`backupExistingFile`), writes with **`Data.write(to:options: .atomic)`** (Foundation's
  own temp-file + rename), prunes to `retainedBackups`, and on `read` **falls back from a
  corrupt/missing primary to the newest valid backup**, throwing
  `AtomicWriterError.noValidBackup` only when nothing parses.
- **`WorkspaceStore`** (`Sources/ContinuumRevivedCore/WorkspaceStore.swift`) already wraps
  it: `save`→`writer.write`, `load`/`tryLoad`→`writer.read` (+ `tryLoad` swallows
  `noValidBackup` → nil), `backupsDirectory` per workspace.
- **`WorkspaceDocumentSaveController`** (`Sources/ContinuumRevived/App/`) already has a
  **0.2 s `Timer`-coalesced** `scheduleZoneLayoutSave(_:)` + `flushPendingSave()`.

So T12 is **NOT** "write an atomic writer." T12 closes the four genuine gaps the brief's
spirit demands but the code does not yet meet:

1. **fsync gap (crash-safe rename):** `Data.write(.atomic)` renames a temp into place but
   does **not** guarantee the temp's bytes are flushed to stable storage *before* the
   rename — a power-loss between write and rename can leave a present-but-empty/partial
   primary while the rename has already unlinked nothing. The brief explicitly demands
   "write temp + **fsync** + rename." Close this in the writer's write path.
2. **Debounce is hardcoded (`0.2`)** — violates configurable-first. Must become a
   `UserDefaults` default + `SettingsSchema` entry + validation guard.
3. **Coalescing is defeated / has no live caller (verified against source):** there are
   exactly **two** `scheduleZoneLayoutSave(_:)` call sites in the whole tree, and each
   constructs a *fresh* local `WorkspaceDocumentSaveController` then immediately
   `flushPendingSave()`s:
   - `ContinuumApp.swift:2994–2996` — inside `addProjectZone(projectId:)`, a **production**
     one-shot action ("Add Project to Canvas"). Immediate flush here is correct (it's a
     discrete user action, not a rapid stream).
   - `ZoneRuntimeController.swift:552–554` — inside `runSaveIsolationSelfCheck()`, which is
     **test scaffolding**, NOT a production lifecycle path. (Earlier framing called this a
     "quit/switch/close" path — that is wrong; the real production save-now lifecycle path
     is the *separate* method `ZoneRuntimeController.flushPendingSaves()` — plural — called
     from `close()`:82 and the ContinuumApp lifecycle sites 2904/2932/2953/2993/3017, and it
     does **not** route through `scheduleZoneLayoutSave` at all.)
   So the debounce *never batches anywhere*, and **no live drag/resize/move autosave caller
   exists yet**. T12 proves real coalescing **at the controller level** (N rapid schedules
   on one persistent controller → **one** write) and confirms an *explicit* `flushPendingSave`
   still writes synchronously. Wiring a production live-autosave caller that benefits from
   the coalescing is NEEDS-HUMAN (b) below — assertion 10 therefore proves the controller's
   batching in isolation, which is real, but note the production-wiring gap.
4. **No crash-safe check exists.** `--persistence-crash-safe-check` is NEW.

The NEEDS-HUMAN design call this raises (which write path gets fsync, given `AtomicWriter`
is shared by ProjectStore/RegistryStore too) is recorded in **Out of scope / gotchas** —
resolve it before implementing.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/AtomicWriter.swift`** — replace the
  `Data.write(to: url, options: .atomic)` line in `write<T>(_:to:)` with an explicit
  durable sequence: write bytes to a sibling temp file (`url` + a `.tmp-<uuid>` suffix in
  the **same directory** so the rename is same-volume/atomic), `fsync` its file
  descriptor, `rename(2)` temp→`url` (raw `rename` — there is no `replaceItemAtomically`
  API), then `fsync` the **parent directory** fd so the rename itself is durable. Add a
  private helper `func atomicDurableWrite(_ data: Data, to url: URL) throws`. Keep the
  existing pre-write round-trip validation, the backup-before-overwrite, and the prune
  exactly as they are. Do NOT change `read`, backup naming, or pruning. NOTE: `write<T>`
  is currently non-throwing on the rename step only because `Data.write` threw; preserve
  the `throws` contract — `atomicDurableWrite` throwing leaves `url` and backups intact.
- **NEW `Sources/ContinuumRevivedCore/AutosaveConfig.swift`** — a small resolver enum
  mirroring `DragMagnetizeConfig`/`TileGapResolver`:
  ```
  public enum AutosaveConfig {
      public static let debounceMsKey = "continuum.autosave.debounceMs"
      public static let defaultDebounceMs = 200
      public static let minDebounceMs = 0
      public static let maxDebounceMs = 5000
      /// Clamped to [min,max]; non-numeric/absent → default. (validation guard)
      public static func debounceMs(defaults: UserDefaults = .standard) -> Int
      /// Convenience: seconds for `Timer.scheduledTimer(withTimeInterval:)`.
      public static func debounceInterval(defaults: UserDefaults = .standard) -> TimeInterval
  }
  ```
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append ONE `.text` field to
  the existing **"general"** section binding `AutosaveConfig.debounceMsKey`, label
  `"Autosave Debounce (ms)"`, default `String(AutosaveConfig.defaultDebounceMs)`. (Mirror
  the `leaderDwellMs` `.text`-ms field.)
- **`Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift`** — read the
  interval from `AutosaveConfig.debounceInterval()` instead of the hardcoded `0.2`. Inject
  a `UserDefaults` (default `.standard`) so the check can drive it. Keep `scheduleZoneLayoutSave`
  / `flushPendingSave` signatures; the timer interval is the only behavior change.
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — add the `--persistence-crash-safe-check`
  branch in the `CommandLine.arguments` dispatch (model on the existing
  `--file-tree-boot-persistence-check` branch at :589). NOTE the dispatch model calls
  `TileSpawner.runFileTreeBootPersistenceSelfCheck()` (that self-check lives on `TileSpawner`,
  NOT on `AppDelegate`). Put the NEW check as a static func on the **`AppDelegate`**
  extension — `static func runPersistenceCrashSafeSelfCheck() throws -> URL` — like the
  other recent app checks (`runWorkspaceSwitchSelfCheck`, `runAddZoneSelfCheck`,
  `runBrowserLRUBudgetSelfCheck` are all `AppDelegate` statics). AppDelegate is the right
  home because the check needs to reach `WorkspaceDocumentSaveController`'s app-module
  members. The dispatch branch then calls `AppDelegate.runPersistenceCrashSafeSelfCheck()`.
- **`scripts/run-matrix.sh`** — register `run_app_check .build/debug/continuum-revived
  --persistence-crash-safe-check` (place it next to `--file-tree-boot-persistence-check`).
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — extend the existing
  **"Settings schema engine"** `do {}` block: add `AutosaveConfig.debounceMsKey` to the
  `expectedKeys` set, and add an `AutosaveConfig` resolver table (default / clamp-low /
  clamp-high / non-numeric → default). This is the configurable-first + validation-guard
  coverage.
- **Do NOT touch:** `read`/backup/prune logic in `AtomicWriter` (only the write→disk
  line); `ProjectStore`/`RegistryStore` call sites (they inherit the durable write for
  free — that is the design question to confirm, NOT a code change here); the document
  *schema* / `ZonePlacement` / group-zone storage (T01/T02 own it); terminal scrollback /
  browser `interactionState` (T13); profiles (T14); the 4 NSEvent monitors; `CanvasEngine`.

## Data / API changes
`AtomicWriter` (private, signature-neutral to callers):
```swift
// in write<T>(_:to:), replace:
//   try data.write(to: url, options: .atomic)
// with:
   try atomicDurableWrite(data, to: url)

private func atomicDurableWrite(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    try data.write(to: tmp)                       // bytes land in a sibling temp (same dir)
    let fd = open(tmp.path, O_RDONLY)              // fsync the temp's data
    if fd >= 0 { fsync(fd); close(fd) }
    // Atomic, same-volume rename. `rename(2)` is POSIX-atomic when src and dst are in
    // the same directory; on failure remove the temp and rethrow so `url` is untouched.
    if rename(tmp.path, url.path) != 0 {
        let err = errno
        try? FileManager.default.removeItem(at: tmp)
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    let dfd = open(dir.path, O_RDONLY)             // fsync the directory entry (rename durability)
    if dfd >= 0 { fsync(dfd); close(dfd) }
}
```
NOTE: `FileManager.replaceItemAtomically` is **not** a real API — do NOT copy that name.
Use the raw `rename(2)` above (simplest, atomic same-dir) **or** `FileManager.replaceItem`.
The load-bearing requirement is exactly: temp in the **same dir** → fsync temp fd → atomic
rename → fsync dir fd. If the temp write or fsync throws (or `rename` fails), the **existing**
`url` is untouched and the leftover temp is removed. (Note `data.write(to: tmp)` with no
options is non-atomic, which is fine here — the temp is throwaway; atomicity comes from the
rename, durability from the two fsyncs.)

`AutosaveConfig` — new resolver enum as above.

`WorkspaceDocumentSaveController.init(store:defaults:)` gains `defaults: UserDefaults =
.standard`; the timer uses `AutosaveConfig.debounceInterval(defaults: defaults)`.

`SettingsSchema` — one appended `.text` field. No struct changes.

## The check, written FIRST (spec-as-test) — `--persistence-crash-safe-check`
NEW app check. Register in `scripts/run-matrix.sh` AND the `ContinuumApp.swift` arg
dispatch. Implemented as `static func AppDelegate.runPersistenceCrashSafeSelfCheck()
throws -> URL` (static so it reaches `WorkspaceDocumentSaveController`'s members; model the
body on `TileSpawner.runFileTreeBootPersistenceSelfCheck` — note that model lives on
`TileSpawner`, but the new one goes on `AppDelegate` — copy the *shape*: temp dirs, local
`CheckError`/`expect`, manifest written to `qa-runs/<ts>/persistence-crash-safe/manifest.json`).

It drives the **real** store + the **real** debounced save controller against a
`CONTINUUM_APP_SUPPORT` temp dir. Use an isolated `UserDefaults(suiteName:)` so the
debounce-interval assertions don't touch the global domain (mirror the
`DragMagnetizeChecks` suite handling in main.swift). Set a tiny interval (e.g. 10 ms) for
the coalescing timing window. Every assertion, hand-derivable:

**A. Durable atomic write reaches disk (real store path)**
1. `WorkspaceStore(workspaceId: WS, applicationSupportDirectory: tmp)`; build a
   `WorkspaceDocument` D1 (viewport `(x:5,y:7,zoom:1.5)`, one project zone + one group
   zone from T01/T02 so optional `projectId` is exercised, `zoneZOrder` of both,
   `lastActiveZoneId` = the group zone). `store.save(D1)`.
2. Assert `store.layout.canvasFile` exists and `store.load() == D1` (the full document
   round-trips through the real reader). → primary is the good doc.
3. Assert **no leftover temp file**: `contentsOfDirectory` of the workspace dir contains
   no entry matching `.canvas.json.tmp-*` (the durable write cleaned up its temp).

**B. Crash mid-write → primary corrupt → reload recovers from backup (no data loss)**
4. `store.save(D2)` where D2 = D1 with `viewport.zoom = 3.0` (so the prior good copy D1 is
   now in `backups/`). Assert `store.load() == D2`.
5. **Simulate a crash that left a corrupt primary:** overwrite `canvasFile` with truncated
   garbage bytes (`Data("{ \"schemaVer".utf8)` — valid-looking prefix, unparseable). This
   is exactly the on-disk state a power-loss-after-rename / partial-flush yields.
6. The reader, finding the primary uncorruptable, **falls back to the newest valid backup**.
   DERIVE the recovery target precisely from the write history:
   - Step 1 `save(D1)`: no prior primary existed → **0 backups created**. backups = {}.
   - Step 4 `save(D2)`: backs up the prior primary D1 → backups = {D1}. primary = D2.
   - Step 5: primary overwritten with garbage out-of-band. backups unchanged = {D1}.
   So on `read`: primary (garbage) fails to decode → newest (only) backup is **D1** → it
   parses → **returns D1**. Assert `store.load() == D1` AND `store.load().viewport.zoom == 1.5`
   (D1's zoom). **The recovered doc is D1, NOT D2** — D2 lived only in the primary, which
   the simulated crash destroyed, and was never backed up. **No half-written doc is ever
   returned** (the garbage never decodes to a `WorkspaceDocument`). *(Do NOT assert "== D2"
   here — that would be the bug. The recovery target is the last-good *backup*, which is D1.)*
7. **Truncated-temp survivability:** hand-place a stray `.canvas.json.tmp-<uuid>` file
   containing partial bytes in the workspace dir, then `store.load()` — assert it still
   returns D1 (a leftover temp is never mistaken for the primary or a backup; backup
   matching is by name prefix `canvas.` + ext `.json`, temps are dot-prefixed and excluded).

**C. Pre-write validation never corrupts the primary**
8. Confirm the good primary survives a *would-be* bad write: this is already guaranteed by
   the existing encode-round-trip gate (write throws before touching disk on un-encodable
   input). Assert by reading the writer contract: after step 6 recovers D1, `store.save(D1)`
   succeeds and `store.load() == D1` (writer still healthy post-recovery).

**D. Debounced coalescing through the REAL controller (one atomic write for N mutations)**
9. Build `WorkspaceDocumentSaveController(store: store, defaults: suite)` with
   `suite.set("10", forKey: AutosaveConfig.debounceMsKey)` (10 ms window). Call
   `scheduleZoneLayoutSave` **5 times in a tight loop** with documents D_a…D_e (distinct
   `viewport.x` 10,11,12,13,14) **without** an interleaved flush. Spin the runloop
   (`RunLoop.current.run(until: Date()+0.05)`) past the window.
10. Assert exactly **one** write landed for those 5 schedules by counting backups created
    in the window (each `write` backs up the prior primary; 5 immediate writes would
    create ≥4 new backups, one coalesced write creates exactly 1). DERIVE: pre-D state has
    primary P0 + its backups; after coalesced flush, exactly one new backup of P0 appears
    and the primary == D_e (the last scheduled, `viewport.x == 14`). Measure as a **delta**:
    `nBackupsBefore = backupFileCount()` taken immediately before the 5 schedules,
    `nBackupsAfter` after the runloop spin; assert `nBackupsAfter - nBackupsBefore == 1`
    AND `store.load().viewport.x == 14`.
    **PRUNING TRAP — must address:** `WorkspaceStore`'s default is `retainedBackups: 3`, and
    `write` prunes to that cap *after* each backup. By step 9 the backups dir already holds
    several entries (D1 from step 4, the garbage-primary backup from step 8, etc.), so a
    naive count delta can be confounded by pruning (a new backup that pushes over the cap
    triggers a prune → delta 0, not 1, and the assertion silently breaks or goes flaky).
    Construct the `WorkspaceStore` used by this check with a **generous** `retainedBackups`
    (e.g. `retainedBackups: 64`) so pruning never fires within the check and the delta is a
    faithful write count. Count backups by listing `store.layout.backupsDirectory` and
    filtering the backup-name pattern (prefix `canvas.` + suffix `.json`), NOT by trusting a
    fixed pre-count. Do this from step 1 onward (one store instance for the whole check).
11. **Explicit flush still works:** call `scheduleZoneLayoutSave(D_f)` (viewport.x 15) then
    `flushPendingSave()` synchronously; assert `store.load().viewport.x == 15` immediately
    (no runloop spin needed — flush is synchronous).

**E. Configurable interval is read from defaults (real wiring, not constant)**
12. `AutosaveConfig.debounceMs(defaults: emptySuite) == 200` (default).
13. `emptySuite.set("750", …)` → `debounceMs == 750`; `set("-5",…)` → clamps to
    `minDebounceMs (0)`; `set("99999",…)` → clamps to `maxDebounceMs (5000)`;
    `set("abc",…)` → falls back to `200`. (validation/clamp guard)
14. The save controller actually USES it: construct a controller with `defaults` whose
    `debounceMs == 0`, schedule one doc, spin one runloop pass, assert it flushed (a 0 ms
    interval fires next-loop) — proving the controller reads the config, not the literal
    `0.2`.

Write the manifest (recovered viewport, backup counts, coalesce count) and return its URL.

**RED first — be honest about which assertions actually go RED.** Audit the real
controller before writing the check: `WorkspaceDocumentSaveController.scheduleZoneLayoutSave`
*already* coalesces inside the controller (it invalidates and reschedules a single `Timer`;
it does **not** flush inline — the immediate flush is at the two call sites only). So when
assertion 9 schedules 5 times on a *bare persistent controller without flushing*, the
EXISTING controller already produces ONE write. Therefore:
- The compile RED is genuine: missing `AutosaveConfig` (the check won't build).
- Assertion **3** (durable-write temp hygiene: no `.canvas.json.tmp-*` leftover) is the
  real behavioral RED for the **fsync/durable-write** change. With the current
  `Data.write(.atomic)`, Foundation writes its own temp under a different name and cleans
  it up, so assertion 3 may *already* pass; the durable-write change introduces the
  dot-prefixed sibling temp and must leave none behind — write assertion 3 to fail if a
  `.canvas.json.tmp-*` survives, which is the observable of the new code path.
- Assertion **14** (controller honors a 0 ms `AutosaveConfig` and fires next-loop) is the
  real behavioral RED for the **configurable-debounce** change: with the controller still
  hardcoded to `0.2`, a 0 ms config does NOT fire within one runloop pass → RED until the
  controller reads `AutosaveConfig.debounceInterval`.
- Assertion **10** (coalescing == 1 write) most likely passes on the EXISTING controller
  (it already coalesces). It is a **guard/regression assertion**, NOT this task's RED — it
  exists so a future change that reintroduces inline flushing is caught. State this honestly;
  do NOT claim assertion 10 is the RED. If, when you write it, assertion 10 happens to pass
  immediately, that is EXPECTED (the controller already coalesces) — it is not a
  mis-specified task, because the task's genuine deltas are the durable write (assertion 3)
  and configurable debounce (assertions 12–14).
Add a minimal compiling `AutosaveConfig` stub (returns 200, no clamp), build, run → RED on
the **clamp table** (assertion 13, CoreChecks) and assertions **3** and **14**. Implement to GREEN.

## Implementation steps
1. Write `--persistence-crash-safe-check` (all 14 assertions) + register in
   `scripts/run-matrix.sh` and the `ContinuumApp.swift` dispatch. Add a compiling
   `AutosaveConfig` stub (returns 200, no clamp). `swift build`; run it → **RED** on
   coalescing + temp-hygiene assertions.
2. Implement `AutosaveConfig` fully (key, default, clamp `[min,max]`, non-numeric→default,
   `debounceInterval` = ms/1000). Add the `.text` field to `SettingsSchema` "general"; add
   its key to `expectedKeys` + the resolver table in CoreChecks main.swift.
3. Point `WorkspaceDocumentSaveController` at `AutosaveConfig.debounceInterval(defaults:)`;
   add the `defaults` init param.
4. **Coalescing:** make the controller actually batch — keep `scheduleZoneLayoutSave`
   timer-driven (it already is). The ONE production caller, `addProjectZone`
   (ContinuumApp:2994–2996), is a discrete user action; its immediate `flushPendingSave()`
   is correct and **stays**. The ZoneRuntimeController:552–554 site is inside
   `runSaveIsolationSelfCheck()` (test code) — leave it. **Do not invent a live-autosave
   caller in this task** unless NEEDS-HUMAN (b) is resolved to "add a live path": there is
   no drag/resize/move handler today that schedules an autosave, so the coalescing behavior
   is exercised by the check at the controller level (assertion 10 builds its own persistent
   controller and schedules 5 docs without flushing). The behavior change this task ships is
   strictly: (i) the controller reads the interval from `AutosaveConfig` instead of `0.2`,
   and (ii) the controller demonstrably coalesces N rapid schedules into one write when not
   flushed. The production wiring (which mutation handler should schedule the live autosave)
   is flagged below; if you resolve it to "wire it now," that is a scope addition to confirm
   with the human first.
5. **Durable write:** replace the `.atomic` line in `AtomicWriter.write` with
   `atomicDurableWrite` (temp in same dir → fsync temp fd → atomic rename → fsync dir fd),
   preserving the pre-write round-trip validation + backup + prune. `swift build`.
6. Run the check → **GREEN**. Then `./scripts/run-matrix.sh --fast` (the durable-write
   change touches the shared writer — also run `--zone-save-isolation-check`,
   `--browser-restore-state-check`, `--browser-profile-persistence-check`,
   `--file-tree-boot-persistence-check`, `--viewport-sanitize-check` to prove no
   ProjectStore/RegistryStore persistence regressed).
7. Self-review against Acceptance + Review rubric; commit
   `feat(persistence): durable atomic autosave + crash-safe reload + configurable debounce`.

## Acceptance criteria
- [ ] `--persistence-crash-safe-check` registered (run-matrix.sh + ContinuumApp dispatch),
      all 14 assertions drive the REAL `WorkspaceStore` + real `WorkspaceDocumentSaveController`.
- [ ] Corrupt-primary reload recovers the **newest valid backup** (asserted to the exact
      `viewport.zoom == 1.5` / D1), never returns a half-written doc.
- [ ] Durable write: no `.canvas.json.tmp-*` leftover after a save; a stray temp is never
      loaded as primary or backup.
- [ ] N rapid `scheduleZoneLayoutSave` coalesce into exactly **one** atomic write (backup
      count == 1; primary == last-scheduled); explicit `flushPendingSave` still writes now.
- [ ] Debounce interval is `AutosaveConfig` (UserDefaults default 200 + clamp guard) + a
      `SettingsSchema` "general" `.text` field; CoreChecks asserts the key + clamp table.
- [ ] `swift build` clean; `./scripts/run-matrix.sh --fast` green; the ProjectStore/Registry
      persistence checks listed in step 6 green.
- [ ] No schema/T13/T14 surface touched; commit message has no co-author footer.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks            # configurable + clamp table
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --persistence-crash-safe-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```

## Review rubric
- **Bypass audit (critical):** the check must go through `WorkspaceStore.save/load` and
  `WorkspaceDocumentSaveController.scheduleZoneLayoutSave`, NOT call `AtomicWriter.write`
  directly. If it pokes the writer or hand-rolls the timer, REWORK.
- **Recovery target is exact, not "it loaded something":** assertion 6 must assert the
  *specific* recovered document (D1, `zoom == 1.5`) derived from the backup ordering — a
  check that only asserts "load() didn't throw" hides the half-written-doc bug. Re-derive
  the backup set by hand (step 4 backs up D1 → newest backup is D1).
- **Coalescing proven by write count, not by final value alone:** assertion 10 counts
  backups created in the window. A check that only reads the final `viewport.x` would pass
  even with 5 separate writes — insist on the count == 1.
- **Durable write doesn't silently regress the shared writer:** confirm the
  ProjectStore/RegistryStore-backed checks (step 6) are green; the fsync path must not
  break `Data.write`-based callers (notes use `.atomic` directly — out of scope, untouched).
- **Configurable, not theater:** assertion 14 must show the *controller* honoring a 0 ms
  config (fires next loop), proving it reads `AutosaveConfig`, not the old `0.2` literal.
- **Clamp guard present:** negative / huge / non-numeric all resolve safely (no crash, no
  unbounded timer).
- Would the check go RED if you reverted the fsync line? (No — fsync durability isn't
  observable in a normal process exit.) **Acknowledge this**: the fsync change is asserted
  by the *temp-hygiene + same-dir-rename* observable (assertion 3/7), plus a code-review
  gate that the rename is same-volume and the dir fd is fsynced. True power-loss isn't
  headless-simulable; the check proves the *crash-left-corrupt-primary* recovery path,
  which is the user-visible guarantee. State this honestly in the manifest.

## Out of scope / gotchas
- **NEEDS-HUMAN — which write path gets fsync.** `AtomicWriter` is shared by
  `WorkspaceStore`, `ProjectStore`, AND `RegistryStore`. Adding fsync to
  `AtomicWriter.write` makes *every* persisted JSON durable (good, but widens T12's stated
  "WorkspaceStore" scope to a shared primitive). The alternative — a workspace-only durable
  writer — duplicates logic and diverges the backup format. **Decision needed before
  implementing:** (a) fsync in the shared `AtomicWriter` (recommended; one code path, all
  stores benefit, surgical one-line swap) and accept that T12's blast radius is the shared
  writer with the ProjectStore/Registry checks as the regression gate; or (b) a
  WorkspaceStore-local override. This spec is written for (a); confirm or override.
- **NEEDS-HUMAN — there is NO live-autosave production caller (verified, not assumed).**
  The whole tree has exactly two `scheduleZoneLayoutSave` callers:
  `ContinuumApp.swift:2994–2996` (`addProjectZone` — a discrete production action, flushes
  immediately, correct) and `ZoneRuntimeController.swift:552–554` (inside
  `runSaveIsolationSelfCheck()` — **test scaffolding**, not a lifecycle path). The genuine
  production "save now" lifecycle path is the *separate* `ZoneRuntimeController.flushPendingSaves()`
  (plural), which writes through `store.save` directly and never touches the debounced
  controller. **So no drag/resize/move handler currently fires a debounced autosave at
  all.** Consequence: the coalescing fix has no production caller to exercise; assertion 10
  proves the *controller's* batching in isolation (real, but isolated). DECISION NEEDED:
  (a) ship T12 as the durable-writer + configurable-debounce + controller-level-coalescing
  proof, and leave "wire a live drag/resize/move autosave that schedules-without-flushing"
  to the wiring task (recommended — keeps T12 surgical; the live caller belongs with the
  mutable-canvas/gesture tasks T05/T11/T19 that own the mutation handlers); or (b) add the
  live non-flushing schedule call now (scope addition — confirm before doing it). This spec
  is written for (a). Do NOT delete or alter `flushPendingSaves()` (plural) — it is the
  correct lifecycle save-now path and is out of scope.
- **`replaceItem` vs `rename`:** `FileManager.replaceItem` preserves metadata but can fall
  back to copy across volumes; since the temp is in the **same directory** as `url`, a raw
  `rename(2)` is atomic and simplest. Either is fine; do NOT write the temp to
  `temporaryDirectory` (cross-volume → non-atomic rename → defeats the whole point).
- **Backup-name exclusion:** temps are dot-prefixed (`.canvas.json.tmp-*`); the backup
  scanner filters by prefix `canvas.` (no leading dot) + suffix `.json`, and
  `contentsOfDirectory` uses `.skipsHiddenFiles` — so a leftover temp is doubly excluded.
  Verify assertion 7 against this, don't assume.
- T13 (terminal cwd+scrollback, browser `interactionState`) and T14 (profiles) layer on
  this document; do not add their fields here.
- Stale SourceKit "cannot find AutosaveConfig" resolves on `swift build` — build is
  authoritative.
