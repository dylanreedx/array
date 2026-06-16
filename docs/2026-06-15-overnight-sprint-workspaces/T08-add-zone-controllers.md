# T08 — `addZone` spins a real controller + an ambient controller for group zones

Status: todo
Tag: overnight [appkit-checkable]
Depends on: T06 (WorkspaceRuntime shell), T02 (group-zone tile storage) · Blocks: —

Keystone stage: docs/23 **S6** — "`addZone(projectId:)`: addProjectZone spins up a real
controller + layer." This task generalizes S6 to BOTH zone kinds (the charter §1 split):
a **project zone** acquires its shared `ZoneRuntimeController` via the registry; a **group
zone** (`projectId == nil`) gets an **ambient rootless controller** rooted at a
configurable home dir, with its tiles stored in the workspace store (T02).

## Goal
Adding a zone to the live canvas actually *brings it to life*. Today
`AppDelegate.addProjectZone` (ContinuumApp.swift:2961) only persists a placement — it
spins up **no** runtime and installs **no** live layer; the zone is a dead header
rectangle until relaunch. After T08, calling the real add path:
- **Project zone:** acquires (ref-counts) the project's one shared `ZoneRuntimeController`
  through the registry (T04) and installs its `ZoneLayer` on the mutable canvas (T05).
- **Group zone:** creates a rootless **ambient** controller rooted at a configurable home
  directory (default `$HOME`), stores its tiles in the workspace store (T02), and installs
  its layer.
This is the capability behind charter §4's "a **group zone** (no project) can be created…
holds tiles, and persists across quit/relaunch."

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/WorkspaceRuntime.swift`** (created in T06) — add
  `addZone(...)` (the single real entry point that both the ⌘K "add project to canvas"
  row and the future sidebar/gesture call). It must:
  - **project zone path:** resolve the project's `rootPath` from the registry, call
    `registry.acquire(projectId:)` (T04 — create-if-missing, ref-count++), get back the
    shared `ZoneRuntimeController`, append a project `ZonePlacement` to the active
    `WorkspaceDocument` (reuse `WorkspaceDocument.appendProjectZone`, T01-shaped), and
    install the zone's `ZoneLayer` on the canvas via the T05 mutable API
    (`canvasView.upsertZoneLayer` / `setZonePlacement`).
  - **group zone path** (`projectId == nil`): create an **ambient** rootless
    `ZoneRuntimeController` rooted at `AmbientZoneHome.current` (the new resolver below),
    append a group `ZonePlacement` (via T02's group-zone append — see Data/API), persist
    its (initially empty) tile list in the **workspace store** (T02), and install its
    `ZoneLayer`.
  - persist: schedule + flush the `WorkspaceDocument` save (mirror today's
    `WorkspaceDocumentSaveController.scheduleZoneLayoutSave` + `flushPendingSave` at
    ContinuumApp.swift:2994–2996) and the registry save.
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** —
  - `addProjectZone(projectId:)` (:2961) becomes a thin forwarder to
    `workspaceRuntime.addZone(projectId: projectId)` (keep the call sites at :1162, :2827,
    :5175 working). Do **not** keep two divergent copies of the load/append/save logic —
    the logic moves into `WorkspaceRuntime.addZone`.
  - register the new `--add-zone-check` dispatch (it already exists at :566 — you
    **extend** `runAddZoneSelfCheck`, not add a second flag).
- **`Sources/ContinuumRevivedCore/AmbientZoneHome.swift`** (NEW, ~30 lines) — the
  configurable ambient-cwd resolver, modeled exactly on `DefaultBrowserURL.swift`:
  `userDefaultsKey = "continuum.ambientZoneHome"`, `fallback = NSHomeDirectory()`,
  `static func resolvedFromDefaults(standardDefaults:) -> AmbientZoneHomeResolution`,
  `static var current: String`. Empty/whitespace-only/non-existent-directory override →
  fall back to `$HOME` (so a typo can't root an ambient zone at a bogus path).
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append ONE `.text` field to
  the `"general"` section binding `AmbientZoneHome.userDefaultsKey` (default
  `AmbientZoneHome.fallback`). (configurable-first.)
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — extend the existing Settings-schema
  Core block to add `AmbientZoneHome.userDefaultsKey` to the `expectedKeys` set
  (**main.swift:3949–3959**, asserted a subset of `fieldKeys` at :3960), plus a resolver
  round-trip in an isolated suite (empty defaults → `$HOME`; valid override dir → that dir;
  bogus/non-existent override → `$HOME`). Model the isolated-suite round-trip on the
  **DragMagnetize block at main.swift:3962–3969** (`UserDefaults(suiteName:)` + scrub +
  `defer { removePersistentDomain }`), passing `AmbientZoneHome.resolvedFromDefaults(
  standardDefaults:directoryExists:)` the suite and a stub `directoryExists` so the
  bogus-path case is deterministic without touching the real FS. This is the conflict-guard
  coverage for the new key — the existing `Set(fieldKeys).count == fieldKeys.count`
  uniqueness assertion (**main.swift:3946**) already guards against a duplicate key; your new
  key must not collide.
- **Do NOT touch:**
  - `switchWorkspace` (T09) — T08 only *adds* a zone to the already-active workspace.
  - **Tile-between-zone migration** (charter §1 "Deferred to v2") — moving a tile between a
    project zone and a group zone is explicitly out.
  - `ZoneRuntimeRegistry` **internals** (T04 owns `acquire`/`release`/ref-count/close — call
    it, do not reimplement or modify it).
  - `removeZone` (separate; the WorkspaceRuntime API lists it but T08 only adds).
  - The 4 window-scoped NSEvent monitors / `FocusBroker` plumbing (ADR-0024).
  - `CanvasEngine` transforms; `relaunchApplication` (stays for project-root change only).

## Data / API changes
**`AmbientZoneHome` (new, copy-pasteable skeleton — mirror `DefaultBrowserURL`):**
```swift
public enum AmbientZoneHome: Sendable {
    public static let userDefaultsKey = "continuum.ambientZoneHome"
    public static var fallback: String { NSHomeDirectory() }
    public static var current: String { resolvedFromDefaults().path }
    public static func resolvedFromDefaults(
        standardDefaults: UserDefaults = .standard,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AmbientZoneHomeResolution { /* override→validate dir→fallback to $HOME */ }
}
public struct AmbientZoneHomeResolution: Equatable, Sendable {
    public enum Source: String, Sendable { case standardDomain, fallbackDefault }
    public let path: String          // always an existing absolute dir
    public let rawValue: String?
    public let source: Source
}
```
**`WorkspaceRuntime.addZone` (the real entry point — exact signature to be finalized
against T06's `WorkspaceRuntime` shape; the keystone API list in docs/23 names
`addZone(projectId:)`):**
```swift
@discardableResult
@MainActor func addZone(projectId: UUID?) -> UUID   // returns the new zoneId
// projectId != nil → project zone (registry.acquire); projectId == nil → group zone (ambient)
```
> NEEDS-HUMAN (see Out of scope): the precise `addZone` signature, the `ZoneRuntimeRegistry`
> `acquire` return type, the T05 `upsertZoneLayer` signature, and the **group-zone append
> API on `WorkspaceDocument`/`WorkspaceStore`** are all defined by the upstream tasks
> T06/T04/T05/T02, which are **not yet written/built**. Pin them from the merged upstream
> code before implementing; the assertions below are expressed against observable end-state
> (registry contents, installed layers, on-disk JSON) so they survive small signature drift.

**`appendProjectZone` (T01-shaped):** already takes `projectId`; T01 makes
`ZonePlacement.projectId` optional and adds `name`/`navKey`. T08's group-zone path uses
**T02's** group-zone append (`projectId == nil`, a default group name, group tile storage)
— do not overload `appendProjectZone` with a nil project.

## The check, written FIRST (spec-as-test) — extend `--add-zone-check`
Flag already registered (ContinuumApp.swift:566 → `runAddZoneSelfCheck`; run-matrix.sh:108).
You **replace the body** of `runAddZoneSelfCheck` so it drives the **REAL** `addZone` path
instead of the current pure `appendProjectZone`+`WorkspaceStore` round-trip (which is a
bypass — it never touches the AppDelegate/runtime/registry/canvas and would still pass with
`addZone` stubbed). Keep the function name + flag + return type (`URL`) so the matrix entry
and dispatch are unchanged.

**Harness (real path):** build a temp `CONTINUUM_APP_SUPPORT` + temp project roots; seed a
`Registry` with one workspace `W` and one real project `P` (a temp dir with a
`.continuum-revived`), persist an empty `WorkspaceDocument` for `W`. Construct a real
`AppDelegate()`, point its `registryStore` at the temp app-support, and bring up its
`workspaceRuntime` for workspace `W` with a real `CanvasNSView` + `FocusBroker` attached.
Real seams to mirror (verified in source today):
- `AppDelegate()` is constructed directly in many checks; `delegate.registryStore`,
  `delegate.canvasView`, and `delegate.zoneRuntimeController` are all assignable from a
  static check (checks live on `AppDelegate` to reach `private` members) — see the existing
  agent-attention harness at **ContinuumApp.swift:3633–3648** (`let delegate = AppDelegate();
  delegate.canvasView = …; delegate.zoneRuntimeController = ZoneRuntimeController(…)`) and the
  nav harness at **:6499–6513** (`navApp.registryStore = registryStore`).
- `workspaceRuntime` is the **T06-introduced** property and **does not exist yet** — pin its
  attach/boot API (and whether it replaces or wraps `delegate.zoneRuntimeController`) from the
  merged T06 code; the boot wiring it should mirror is the real app path at
  **ContinuumApp.swift:1052–1156** (registry load + canvas construction at :1099).

Set `AmbientZoneHome`'s defaults suite to a temp dir `Hgroup` (an existing dir) so the
ambient cwd is deterministic and asserts the configurable resolver. Then exercise **both**
kinds through the production method.

**Part A — project zone (real path):** call
`delegate.addProjectZone(projectId: P.id)` (the real menu/⌘K entry, which now forwards to
`workspaceRuntime.addZone`). Assertions:
1. **Registry acquired:** `workspaceRuntime`'s `ZoneRuntimeRegistry` now holds a controller
   keyed by `P.id` with **ref-count == 1** (introspect the registry — T04 exposes a
   count/contains; a green check requires it).
2. **Controller identity = project:** that controller's `projectRoot` == P's `rootPath`
   (`ZoneRuntimeController` exposes a single `projectRoot: URL`, confirmed at
   `ZoneRuntimeController.swift:7`; the project-rooted `init(projectRoot:projectStore:project:)`
   path also carries `project.id` — assert either, but `projectRoot.path == P.rootPath` is
   the load-bearing one). It is rooted at P, **not** at `$HOME`.
3. **Layer installed:** the canvas's installed zone layers include exactly one layer whose
   `placement.projectId == P.id` (probe the T05 mutable-canvas API:
   `canvasView.installedZoneIds` / `zoneLayer(for:)` — name it against T05). The layer's
   placement `projectId == P.id`.
4. **Document persisted:** reload `W`'s `WorkspaceDocument` from a fresh `WorkspaceStore`
   off disk → it contains a zone with `projectId == P.id`; `lastActiveZoneId` == that zone;
   `zoneZOrder` ends with that zoneId.
5. **Idempotent (D1, one zone per project per workspace):** call
   `addProjectZone(projectId: P.id)` **again** → registry ref-count for `P` is **still 1**
   (re-acquired the same instance, did not create a second controller — assert the
   controller instance is `===` the one from assertion 1), and the document still has
   exactly one `P` zone (no duplicate placement). This guards the de-dupe at
   ContinuumApp.swift:2979.

**Part B — group zone (real path):** call `delegate`'s real add-group entry
(`workspaceRuntime.addZone(projectId: nil)` — wire a thin `addGroupZone()` AppDelegate
forwarder if ⌘K/sidebar will call it; the check calls the same production method the UI
calls, NOT a private helper). Assertions:
6. **Ambient controller created:** the registry/runtime now has a group controller whose
   `projectRoot.path == Hgroup` (the configurable ambient home from the defaults suite) —
   i.e. it is **rootless/ambient**, rooted at the resolved home, NOT at `$HOME` literally
   when an override is set, and NOT keyed in the per-`projectId` registry map (a group zone
   has no projectId, so it must not pollute `acquire`/ref-count keyed by projectId — assert
   the projectId-keyed registry count is unchanged from Part A: still just `P`).
7. **Group placement persisted with `projectId == nil`:** reload `W`'s document → it now
   has a second zone with `projectId == nil` and a non-empty `name` (the group default).
8. **Group tiles in the workspace store (T02):** the new group zone's tile list is stored
   in the **workspace store** (T02's group-tile storage), not in any `ProjectStore`. Assert
   the reloaded document/store reports the group zone's tile collection (empty on create is
   fine — assert it *exists and is addressable* via T02's accessor, distinct from project
   zones whose tiles live in `ProjectStore`).
9. **Group layer installed:** the canvas's installed zone layers now include the group
   zone's layer (`installedZoneIds` count == 2: one P-project, one group); the group layer's
   placement has `projectId == nil`.

**Part C — configurable ambient home (real resolver, drives the persisted default):**
10. With `AmbientZoneHome`'s defaults suite scrubbed (empty), `AmbientZoneHome.current ==
    NSHomeDirectory()` (`$HOME` fallback). Set the suite key to `Hgroup` (existing dir) →
    `current == Hgroup`. Set it to a **non-existent** path → `current == NSHomeDirectory()`
    (bogus override rejected). (This is the same suite the Part B group controller read, so
    Part B + Part C together prove the ambient cwd is genuinely configurable end-to-end.)

> Every asserted value is hand-derivable: ref-counts are integers from explicit acquire
> calls; `projectId` equality is from the seeded UUIDs; `Hgroup`/`$HOME` are the literal
> temp/home paths the harness sets; `installedZoneIds.count` is exactly 1 after Part A and 2
> after Part B.

**RED:** with the body replaced to drive `addProjectZone`→`workspaceRuntime.addZone` and
the group path, the check fails (today `addProjectZone` installs no layer and spins no
controller; group `addZone` and `AmbientZoneHome` don't exist) — RED on assertions 1/3/6,
not a compile error once the upstream stubs exist. Implement to GREEN.

## Implementation steps
1. **(RED)** Rewrite `runAddZoneSelfCheck` per the spec above (Parts A/B/C), keeping the
   flag/name/return. Add `AmbientZoneHome.swift` + the SettingsSchema field + the Core
   resolver assertions. `swift build`; run `--add-zone-check` → RED on assertion 1/3
   (project layer/controller not installed) — confirm it's an *assertion* failure once the
   T06/T04/T05/T02 symbols compile, not a missing-member error. If it fails to compile
   because an upstream symbol is absent, that upstream task isn't merged → stop (deps not
   Done).
2. Implement `WorkspaceRuntime.addZone(projectId:)`:
   - project path: resolve `rootPath` from registry; `registry.acquire(projectId:)`;
     `document.appendProjectZone(...)` with de-dupe (reuse the :2979 guard);
     `canvasView.upsertZoneLayer(...)` for the placement; flush document + registry saves.
   - group path: `let home = AmbientZoneHome.current`; create the ambient
     `try ZoneRuntimeController(root: URL(fileURLWithPath: home), acquireLock: false)` — the
     **real** rootless initializer at `ZoneRuntimeController.swift:54`
     (`init(root projectRoot: URL, acquireLock: Bool = true) throws`); it maps `root` →
     `projectRoot`, and `acquireLock: false` means no project lock. T02 group-zone append
     (`projectId == nil`, default name); persist group tiles via T02; `upsertZoneLayer`;
     flush saves.
3. Repoint `AppDelegate.addProjectZone` (:2961) to forward to
   `workspaceRuntime.addZone(projectId:)`; add a thin `addGroupZone()` forwarder if a UI
   surface needs it (⌘K row is T17 — here just expose the production method the check calls).
   Remove the now-duplicated load/append/save block that moved into WorkspaceRuntime
   (orphan cleanup from THIS change only).
4. **(GREEN)** `swift build` → `--add-zone-check` GREEN → `ContinuumRevivedCoreChecks`
   GREEN (the new resolver + schema key) → `./scripts/run-matrix.sh --fast`. Also re-run
   `--zone-save-isolation-check` and `--multi-zone-render-check` (S6 must not break
   per-controller dirty-tracking or multi-zone render — docs/23 Risk).
5. Self-review against Acceptance + Review rubric; commit
   `feat(zones): addZone spins real + ambient controllers (S6)` (no co-author footer).

## Acceptance criteria
- [ ] `--add-zone-check` drives the **real** `addProjectZone`→`workspaceRuntime.addZone`
      and the real group-`addZone`; it would FAIL if either path were stubbed (no bypass).
- [ ] Project zone: registry acquires P's controller (ref-count 1), layer installed,
      document persisted; second add is idempotent (ref-count stays 1, no duplicate zone).
- [ ] Group zone: ambient rootless controller rooted at the **configurable** home; placement
      persisted with `projectId == nil` + a name; tiles stored in the workspace store (T02);
      layer installed; the projectId-keyed registry is NOT polluted by the group zone.
- [ ] `AmbientZoneHome` resolver: `$HOME` fallback, valid override honored, bogus override
      rejected — asserted in the Core checks; SettingsSchema has the new `.text` field; the
      key is in `expectedKeys`; uniqueness guard still green (conflict-guard).
- [ ] Fast matrix green; `--zone-save-isolation-check` + `--multi-zone-render-check` green.
- [ ] Only the named files touched; no `switchWorkspace`/registry-internals/tile-migration
      changes; orphaned old `addProjectZone` body removed.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --add-zone-check; rm -rf "$P" "$A"
.build/debug/continuum-revived --zone-save-isolation-check
.build/debug/continuum-revived --multi-zone-render-check
./scripts/run-matrix.sh --fast
```

## Review rubric (adversarial)
- **Bypass audit (critical):** the check must call `delegate.addProjectZone(...)` /
  `workspaceRuntime.addZone(...)` — the REAL method the menu/⌘K/sidebar invoke — and assert
  on **installed canvas layers + registry contents + on-disk JSON**. If it still calls
  `WorkspaceDocument.appendProjectZone` + `WorkspaceStore.save/load` directly (the old
  body), it proves nothing about S6 → REWORK. Ask: would it pass if `addZone` installed no
  layer and spun no controller? It must not.
- **Registry by instance:** assertion 5's idempotency must be asserted by `===` controller
  identity and an integer ref-count, not "the dict still has one key."
- **Ambient is genuinely ambient + configurable:** assertion 6 must read the controller's
  actual `projectRoot` and compare to the temp `Hgroup` the suite set — not to `$HOME`
  hardcoded. The group controller must be created `acquireLock: false` (a rootless ambient
  zone must not grab a project lock). Confirm the group zone did NOT increment the
  projectId-keyed ref-count map (it has no projectId).
- **Persistence proves group tiles live in the workspace store (T02), not ProjectStore** —
  re-derive by reloading off disk, not by reading the in-memory document the runtime holds.
- **Configurable-first:** new key has a default + a SettingsSchema entry + the Core
  resolver/uniqueness assertions; no hardcoded `$HOME` in the runtime (it reads
  `AmbientZoneHome.current`).
- **Diff vs scope:** `switchWorkspace`, registry internals, tile-migration untouched; the
  old `addProjectZone` body fully migrated (no dead duplicate); no co-author footer.

## Out of scope / gotchas
- **NEEDS-HUMAN (deps not yet built):** T08's three upstream tasks — **T06**
  (`WorkspaceRuntime` shell + `addZone`/`activeController` proxy), **T04**
  (`ZoneRuntimeRegistry` with `acquire`/`release`/ref-count introspection), **T05** (mutable
  `CanvasNSView` `upsertZoneLayer`/`installedZoneIds`/`ZoneLayer`), and **T02** (group-zone
  tile storage + a group-zone append on `WorkspaceDocument`/`WorkspaceStore`) — **do not
  exist in the source today** (only docs/23 + the charter index name them; T02/T04/T06 task
  files aren't written yet, and `ZonePlacement.projectId` is still non-optional `UUID`
  pre-T01). The exact signatures of `addZone`, `registry.acquire`'s return, `upsertZoneLayer`,
  the registry-introspection accessor, and the T02 group-append/group-tile accessor must be
  **pinned from the merged upstream code before implementing**. The assertions here are
  written against observable end-state (registry count, installed layer ids, on-disk JSON)
  precisely so they survive minor upstream signature drift, but a human/agent executing T08
  must confirm those symbols exist and adjust the call sites. If, when T06/T04/T05/T02 land,
  the group-zone storage shape (or `addZone` signature) differs materially from the above, a
  design call is needed on how group tiles are addressed — flag it then.
- **Coordinate model:** the installed group `ZoneLayer` places tiles zone-local→world via
  `CanvasEngine.worldFrame(tile:in:)`; the check asserts layer **presence + placement
  identity**, not pixel frames (frame math is T05/T11's territory).
- **Lock:** the ambient controller is `acquireLock: false` (rootless) — a group zone must
  never contend a project lock. Acquire-failure degradation for project zones is S9 (stretch),
  out of scope here.
- **Tile-between-zone migration** (project↔group) is the one genuinely hard membership case
  and is **deferred to v2** (charter §1) — T08 only creates zones and their initial (empty
  for group) tile storage.
- **SourceKit noise:** "cannot find `WorkspaceRuntime`/`AmbientZoneHome` in scope" will show
  until those land + build; `swift build` is authoritative.
