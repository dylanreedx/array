# T04 — `ZoneRuntimeRegistry` per-projectId, ref-counted (docs/23 S2)

Status: todo
Tag: overnight [pure]
Depends on: — · Blocks: T06, T09

## Goal
Make one `ZoneRuntimeController` exist **per `projectId`**, shared (ref-counted) across
workspaces, so a project that appears in two workspaces gets ONE lock / one PTY set / one
WKWebView set (CON-58 — charter §1 "Why project-owned tiles"; docs/23 S2). This is the
backend bookkeeping `WorkspaceRuntime` (T06) and the in-process switch (T09) build on:
`acquire(projectId:)` hands out the existing controller (creating it once); `release` drops
a reference and closes the controller only when the last workspace lets go.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift`** (NEW file, App target,
  `@MainActor`) — the `ZoneRuntimeRegistry` class: a `[UUID: Box]` map keyed by
  `projectId`, where each `Box` holds the controller + an integer ref-count. Public API
  `acquire` / `release` + introspection for the check. The controller **factory is
  injected** (a closure) so the check can build lock-free controllers (no PTY/WebView).
- **`Sources/ContinuumRevivedCore/ZoneRuntimeBudgetConfig.swift`** (NEW file, Core target)
  — the configurable surface: the persisted default for the registry's only tunable, the
  **ambient (rootless) idle close-delay is NOT this task** — the ONE knob T04 introduces is
  `closeOnZero` policy: whether release-to-zero closes immediately (default `true`) or keeps
  a controller warm for a grace window. See **Data / API changes** for the exact key. (If on
  reading you conclude T04 needs no user-facing knob — see the NEEDS-HUMAN note in
  *Out of scope* — implement the registry without a config file and say so in the commit.)
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append ONE `SettingsField`
  for the new knob in the `general` section (only if the knob is kept; see above).
- **`scripts/run-matrix.sh`** — register `--zone-registry-refcount-check` in the
  `run_app_check` block (it is NEW; grep confirms it is absent).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — add the
  `CommandLine.arguments.contains("--zone-registry-refcount-check")` dispatch block (model
  it on the `--add-zone-check` block at ~:566) calling
  `AppDelegate.runZoneRegistryRefcountSelfCheck()`. The static self-check func itself lives
  on `AppDelegate` (so it can reach the registry's introspection) **or** as a static func on
  `ZoneRuntimeRegistry` invoked from that block — prefer a `static func
  runZoneRegistryRefcountSelfCheck() throws -> URL` on `ZoneRuntimeRegistry` (model it on
  `ZoneRuntimeController.runHydrationLifecycleSelfCheck()` at ZoneRuntimeController.swift:291,
  which already writes a `qa-runs/.../manifest.json` artifact — the artifact-dir + manifest
  block is ZoneRuntimeController.swift:390–412, the `expect(_:_:)` helper :298–300).
- **Do NOT touch:**
  - `ZoneRuntimeController` **internals** (PTY/WebView/lock lifecycle, `attachUI`,
    `setTier`, `dehydrate`/`hydrateToLive`, the save timers). T04 only *calls* its existing
    `init(projectRoot:projectStore:project:)` (lock-free) and `close()`. Do NOT add a
    protocol over it, do NOT change its access levels.
  - `ContinuumApp.zoneRuntimeController` field (:995) and its proxies (:975–997) — the
    field→`workspaceRuntime` migration is **T06 (S4)**, not here. T04 does not wire the
    registry into the live app; it is a standalone, headlessly-checked component.
  - `WorkspaceRuntime` (does not exist yet — **T06**), `ZoneHydrationOrchestrator` (T03),
    `WorkspaceDocument` / `ZonePlacement` (T01), `CanvasNSView`. Any AppKit view code.
  - `BrowserRuntimeBudget` (that is S5/T07).
  - **`Package.swift`** — do NOT edit it. Both new files are auto-globbed into their targets:
    `ContinuumRevived` (executable) uses the implicit `Sources/ContinuumRevived` path with an
    `exclude:` list (no `sources:` allowlist), and `ContinuumRevivedFileTree` *excludes* the
    whole `App/` dir (Package.swift:24–25), so a new `App/ZoneRuntimeRegistry.swift` compiles
    into `ContinuumRevived` (the same target as `ZoneRuntimeController`) with no manifest change.
    `ContinuumRevivedCore` (Package.swift:19) auto-globs all of `Sources/ContinuumRevivedCore`,
    so `ZoneRuntimeBudgetConfig.swift` is picked up automatically. If `swift build` claims it
    can't see one of the new files, the file is in the wrong directory — move it, do NOT add a
    `sources:` entry to Package.swift.

## Data / API changes

New file `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift`:

```swift
import AppKit
import ContinuumRevivedCore
import Foundation

/// One `ZoneRuntimeController` per `projectId`, ref-counted across workspaces
/// (docs/23 S2, CON-58). A project = one lock / one PTY set / one WKWebView set,
/// so it may hydrate only once even when shown in multiple workspaces.
/// `acquire` creates-if-missing and bumps the ref-count; `release` drops it and
/// `close()`s the controller at zero (unless `closeOnZero == false`, which keeps
/// it warm). The controller factory is injected so headless checks build
/// lock-free controllers with no PTY/WebView.
@MainActor
final class ZoneRuntimeRegistry {
    typealias Factory = (UUID) throws -> ZoneRuntimeController

    private struct Box {
        let controller: ZoneRuntimeController
        var refCount: Int
    }

    private var boxes: [UUID: Box] = [:]
    private let makeController: Factory
    private let closeOnZero: Bool

    init(closeOnZero: Bool = ZoneRuntimeBudgetConfig.closeOnZero(),
         makeController: @escaping Factory) {
        self.closeOnZero = closeOnZero
        self.makeController = makeController
    }

    /// Returns the controller for `projectId`, creating it on first acquire,
    /// reusing it (same instance) on subsequent acquires, and incrementing the
    /// ref-count each time.
    @discardableResult
    func acquire(projectId: UUID) throws -> ZoneRuntimeController {
        if var box = boxes[projectId] {
            box.refCount += 1
            boxes[projectId] = box
            return box.controller
        }
        let controller = try makeController(projectId)
        boxes[projectId] = Box(controller: controller, refCount: 1)
        return controller
    }

    /// Drops one reference. At zero, removes the box and (if `closeOnZero`)
    /// invokes `controller.close()`. No-op if `projectId` is not held.
    func release(projectId: UUID) {
        guard var box = boxes[projectId] else { return }
        box.refCount -= 1
        if box.refCount <= 0 {
            boxes.removeValue(forKey: projectId)
            if closeOnZero { box.controller.close() }
        } else {
            boxes[projectId] = box
        }
    }

    // MARK: Introspection (for the check / WorkspaceRuntime)
    var liveCount: Int { boxes.count }
    func refCount(for projectId: UUID) -> Int { boxes[projectId]?.refCount ?? 0 }
    func isLive(_ projectId: UUID) -> Bool { boxes[projectId] != nil }
    func controller(for projectId: UUID) -> ZoneRuntimeController? { boxes[projectId]?.controller }
}
```

New file `Sources/ContinuumRevivedCore/ZoneRuntimeBudgetConfig.swift` (mirrors
`DragMagnetizeConfig` / `BrowserRuntimeBudget`):

```swift
import Foundation

/// Whether the zone runtime registry closes a project's controller the moment its
/// last workspace reference is released (docs/23 S2). Default `true` (bound resources;
/// matches today's single-controller close-on-switch). Set `false` to keep a released
/// controller warm (faster re-acquire; more resident PTYs/WebViews).
public enum ZoneRuntimeBudgetConfig {
    public static let closeOnZeroKey = "continuum.zoneRuntime.closeOnZero"
    public static let defaultCloseOnZero = true

    public static func closeOnZero(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: closeOnZeroKey) != nil
            ? defaults.bool(forKey: closeOnZeroKey)
            : defaultCloseOnZero
    }
}
```

`SettingsSchema.swift` — append to the `general` section's `fields` (after the
`DragMagnetizeConfig` toggle at :72–76):

```swift
                    .toggle(
                        key: ZoneRuntimeBudgetConfig.closeOnZeroKey,
                        label: "Close Project Runtime When Unused",
                        default: ZoneRuntimeBudgetConfig.defaultCloseOnZero
                    ),
```

**Conflict-guard coverage:** `closeOnZero` is a boolean preference, not a keybind — it
cannot collide with a chord, so the keybind conflict-guard (`KnownChordConflicts`) does not
apply. The applicable guard is the **default-resolution guard**: the Core check (below)
asserts `ZoneRuntimeBudgetConfig.closeOnZero()` returns `defaultCloseOnZero` when the key is
absent, and honors an explicitly-set value — i.e. the "no silent hardcode, default is the
documented one, an explicit override wins" guarantee that the `*Config` enums in this
codebase carry. (Same shape as `DragMagnetizeConfig.enabled`.)

## The check, written FIRST (spec-as-test) — `--zone-registry-refcount-check`
Register in `scripts/run-matrix.sh` (a new `run_app_check .build/debug/continuum-revived
--zone-registry-refcount-check` line, grouped with the other zone checks near :106–108) AND
in the `ContinuumApp.swift` arg dispatch (new block modeled on `--add-zone-check` at :566,
printing `ContinuumRevivedZoneRegistryRefcountChecks passed: <artifact path>` and
`Foundation.exit(0)`). The self-check is `ZoneRuntimeRegistry.runZoneRegistryRefcountSelfCheck()
throws -> URL` (writes a `qa-runs/<ts>/zone-registry-refcount/manifest.json` artifact, like
`runHydrationLifecycleSelfCheck`).

**The REAL path.** This is a [pure] backend-bookkeeping task: there is no NSEvent/gesture
path. The "real path" is the registry's **production `acquire`/`release` lifecycle** driven
through the SAME public methods `WorkspaceRuntime` (T06) and `switchWorkspace` (T09) will
call. The check must NOT reach into `boxes` directly or hand-mutate ref-counts; it drives
`acquire(projectId:)`/`release(projectId:)` and asserts on the observable results: returned
controller **instance identity** (`===`), registry **introspection** (`liveCount`,
`refCount(for:)`, `isLive`), and **genuine `close()`** proven by the controller's own
post-close behavior (`setTier(.snapshot)` throws `.controllerClosed`), NOT by "removed from a
dict". The injected factory builds controllers via the lock-free
`ZoneRuntimeController(projectRoot:projectStore:project:)` init over `mktemp` project roots
— so no real PTY/WebView/lock is ever created. The factory also **counts invocations**
(`makeCount[projectId]`) so the check can assert a controller is created exactly once per
acquire-from-zero.

Fixed projectIds (hand-derivable): `P = …0058`, `Q = …0059`. Setup: a factory closure that,
per `projectId`, makes a `mktemp` dir, a `ProjectStore`, a `Project` (id == projectId), and
returns `ZoneRuntimeController(projectRoot:projectStore:project:)`; it increments
`makeCount[projectId]`. Build `registry = ZoneRuntimeRegistry(closeOnZero: true, makeController:
factory)`.

Assertions (every one hand-derivable):

1. **First acquire creates.** `let c1 = try registry.acquire(projectId: P)`.
   `makeCount[P] == 1`; `registry.isLive(P) == true`; `registry.refCount(for: P) == 1`;
   `registry.liveCount == 1`.
2. **Second acquire returns the SAME instance, does NOT create.**
   `let c2 = try registry.acquire(projectId: P)`. `c2 === c1` (instance identity — THE
   sharing guarantee); `makeCount[P] == 1` (still one — no second controller built);
   `registry.refCount(for: P) == 2`; `registry.liveCount == 1`.
3. **Release once keeps it alive (ref-count 2 → 1).**
   `registry.release(projectId: P)`. `registry.isLive(P) == true`;
   `registry.refCount(for: P) == 1`; `registry.controller(for: P) === c1` (same instance,
   not rebuilt); controller is **not** closed — `try c1.setTier(.snapshot)` does NOT throw
   `.controllerClosed` (it throws `.uiUnavailable` instead, since no UI is attached — assert
   the thrown error is `.uiUnavailable`, proving the controller is live, not closed). Restore
   tier is irrelevant (setTier failed before mutating).
4. **Release to zero closes and removes.**
   `registry.release(projectId: P)`. `registry.isLive(P) == false`;
   `registry.refCount(for: P) == 0`; `registry.controller(for: P) == nil`;
   `registry.liveCount == 0`; and **`close()` was genuinely invoked**: `try
   c1.setTier(.snapshot)` now throws `HydrationLifecycleError.controllerClosed` (the
   `isClosed` guard at ZoneRuntimeController.swift:141 fires first). Capture the throw and
   assert it is exactly `.controllerClosed`. This is the assertion that distinguishes a real
   `close()` from "merely removed from the dict".
5. **Acquire after zero builds a FRESH controller.**
   `let c3 = try registry.acquire(projectId: P)`. `c3 !== c1` (new instance);
   `makeCount[P] == 2` (factory invoked a second time); `registry.refCount(for: P) == 1`;
   `registry.isLive(P) == true`. (`c1` stays closed; `c3` is live — independent.)
6. **Two projects are independent.**
   `let q1 = try registry.acquire(projectId: Q)`. `q1 !== c3`; `registry.liveCount == 2`;
   `registry.refCount(for: P) == 1` and `registry.refCount(for: Q) == 1`; `makeCount[Q] == 1`.
   Then `registry.release(projectId: Q)` → `registry.isLive(Q) == false`,
   `registry.isLive(P) == true`, `registry.liveCount == 1` (releasing Q does not touch P).
7. **Over-release is a safe no-op.**
   With `P` at ref-count 1, call `registry.release(projectId: P)` (→ 0, closes), then
   `registry.release(projectId: P)` AGAIN. The second call does not crash, does not throw,
   leaves `registry.refCount(for: P) == 0`, `registry.isLive(P) == false`, `liveCount == 0`.
   Also `registry.release(projectId: Q)` when `Q` is unknown is a no-op (no crash).
8. **`closeOnZero == false` keeps the controller warm.**
   Build a SECOND registry `warm = ZoneRuntimeRegistry(closeOnZero: false, makeController:
   factory2)` (fresh factory/makeCount). `let w1 = try warm.acquire(projectId: P)`;
   `warm.release(projectId: P)`. Then `warm.isLive(P) == false` and
   `warm.refCount(for: P) == 0` (the box is dropped — re-acquire will rebuild), BUT `w1` was
   **NOT** closed: `try w1.setTier(.snapshot)` throws `.uiUnavailable`, NOT
   `.controllerClosed`. (Proves the config knob actually gates `close()`.)
   > Note for the implementer: with the spec'd implementation, `closeOnZero == false` still
   > removes the box at zero (so `isLive` is false / re-acquire rebuilds); it only skips the
   > `close()`. If the intended warm-keep semantics are "keep the box AND skip close so
   > re-acquire returns the same warm instance", that is a DESIGN CHOICE — see the NEEDS-HUMAN
   > flag in *Out of scope*. Write assertion 8 to match whichever you implement, and state it.

9. **Config default-resolution (asserted in THIS self-check via the enum — no separate
   Core-checks entry required for T04):**
   With the key absent, `ZoneRuntimeBudgetConfig.closeOnZero(defaults: <empty suite>) ==
   true`; with the suite explicitly set to `false`, it returns `false`. (Use an isolated
   `UserDefaults(suiteName: "continuum-zone-runtime-closeonzero-\(UUID().uuidString)")` so the
   check never touches `.standard`; `removePersistentDomain` in a `defer`. Mirrors the
   zone-chrome resolution assert in `ContinuumRevivedCoreChecks/main.swift:972–987` and
   `DragMagnetizeConfig.enabled`.) `ZoneRuntimeBudgetConfig` is in Core and importable from the
   App target, so this assert runs cleanly inside `runZoneRegistryRefcountSelfCheck`.

**First confirm the name is genuinely new** (so the RED is real and you do not collide with an
existing check — note `--workspace-switch-check` at ContinuumApp.swift:75 already exists and is
**T09's**, unrelated): `grep -rn "zone-registry-refcount-check" Sources scripts` must return
**nothing** before you start.

Run it → **RED** in two stages:
- **Stage A (no dispatch yet):** with no `--zone-registry-refcount-check` block, the flag
  matches no dispatch and the binary falls through to a normal GUI app launch — it never calls
  `Foundation.exit(0)`, so the run never prints `ContinuumRevivedZoneRegistryRefcountChecks
  passed:` and the `run_app_check` line does not exit 0 (it hangs/needs the harness timeout or
  returns non-zero). That is the *registration* RED, not yet the assertion RED.
- **Stage B (dispatch + stub):** add the dispatch block + a stub `ZoneRuntimeRegistry` whose
  `acquire` ALWAYS builds a new controller and whose `release` is a no-op. Now the check runs to
  the assertions and the RED is the **assertion** failure — specifically **assertion 2**
  (`c2 === c1` fails, and `makeCount[P] == 1` fails, because the stub rebuilt). This is the
  meaningful RED→GREEN boundary. Implement the real ref-count logic to GREEN.

## Implementation steps
1. Create `ZoneRuntimeBudgetConfig.swift` (Core) with the key + default + resolver.
2. Create `ZoneRuntimeRegistry.swift` (App) with the **stub** shape first: real `Box`/`boxes`
   storage but `acquire` ALWAYS builds (ignores existing box) and `release` is a no-op —
   just enough to compile and make assertion 2/3/4 fail on the assertion (RED), not on a
   compile error.
3. Write `static func runZoneRegistryRefcountSelfCheck() throws -> URL` on
   `ZoneRuntimeRegistry` with all 9 assertions + the manifest write (copy the artifact-dir
   pattern from `ZoneRuntimeController.runHydrationLifecycleSelfCheck`, ZoneRuntimeController.swift:390–412).
   Use a local `expect(_:_:)` throwing helper (copy ZoneRuntimeController.swift:298–300).
4. Register the dispatch block in `ContinuumApp.swift` (model on :566) and the
   `run_app_check` line in `scripts/run-matrix.sh` (group with the zone checks near :106).
5. `swift build`; run the single check → confirm **RED on assertion 2** (the `===` identity).
   **← RED→GREEN boundary.**
6. Fill the real `acquire`/`release` ref-count logic (the *Data / API changes* body) →
   run the check → **GREEN**.
7. Append the `SettingsSchema` toggle (if keeping the knob — see scope note).
8. `swift build` → single check → `./scripts/run-matrix.sh --fast`.

## Acceptance criteria
- [ ] `ZoneRuntimeRegistry` (App, `@MainActor`) with `acquire`/`release` + introspection,
      controller **factory injected**.
- [ ] All 9 check assertions pass through the REAL `acquire`/`release` API (no `boxes`
      hand-mutation, no factory bypass); identity asserted by `===`; close proven by the
      `.controllerClosed` throw (not "removed from dict").
- [ ] Acquire twice → same instance, factory invoked once; release-to-zero closes; acquire
      after zero builds fresh; two projects independent; over-release safe; `closeOnZero`
      knob gates `close()`.
- [ ] `ZoneRuntimeBudgetConfig` has a persisted default + `SettingsSchema` entry; default
      resolution asserted (absent → `true`, explicit → honored).
- [ ] `--zone-registry-refcount-check` registered in `run-matrix.sh` + `ContinuumApp.swift`.
- [ ] No `ZoneRuntimeController` internals / AppKit / `WorkspaceRuntime` / `zoneRuntimeController`
      field touched.
- [ ] Fast matrix green; commit `feat(zones): zone runtime registry — per-project ref-counted controllers`.

## Verification commands
```
swift build
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --zone-registry-refcount-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
```

## Review rubric
- **Bypass audit (critical):** the check must drive `acquire`/`release` — the SAME methods
  T06/T09 call — and assert on returned instances + introspection. If it reads or writes
  `boxes` directly, or calls the factory itself and asserts on that, it is a bypass → REWORK.
- **Identity by `===`, not equality:** assertion 2/5 must use reference identity. A struct
  controller or `==` would hide a rebuild. Confirm `ZoneRuntimeController` is a class (it is)
  and `===` is used.
- **`close()` proven, not assumed:** assertion 4 must observe the controller's *own*
  post-close behavior (`setTier` throws `.controllerClosed`). "isLive == false" alone is the
  "removed from a dict" trap the T09 rubric warns about — REWORK if that is the only proof.
- **Factory invocation count:** assertion 2 (`makeCount == 1` after two acquires) and 5
  (`== 2` after re-acquire) are what prove *reuse* vs *rebuild*. Both must be present.
- **`closeOnZero` actually gates close:** assertion 8 must show a released controller is NOT
  closed when the knob is false (`.uiUnavailable`, not `.controllerClosed`). A check that
  only exercises the default path leaves the knob unverified → REWORK.
- **Config default-resolution:** assertion 9 uses an isolated suite (not `.standard`) and
  proves absent→default + explicit→honored. No hardcoded `true` in the registry init.
- **Scope:** no protocol added over `ZoneRuntimeController`; its access levels unchanged; the
  `zoneRuntimeController` field + proxies untouched (that is T06); no AppKit view code.
- Would the check go RED if `acquire` rebuilt every time (stub)? Yes — assertion 2 (`===` /
  `makeCount`). Confirm mentally.

## Out of scope / gotchas
- **Wiring into the live app is T06 (S4).** T04 ships the registry + its check as a
  standalone, headless component. Do not migrate `ContinuumApp.zoneRuntimeController` to a
  `WorkspaceRuntime`-owned registry here.
- **No real PTY/WebView in the check.** The factory uses the **lock-free**
  `ZoneRuntimeController(projectRoot:projectStore:project:)` init (ZoneRuntimeController.swift:71)
  — it acquires no `ProjectLock`, spins up no runtimes (those only appear via `attachUI` +
  `restartBrowserTile`). `close()` on a lock-free, UI-less controller is safe (no lock to
  release, save flushes are guarded by `let canvasView/tileSpawner` being nil). The check
  attaches NO UI — so `setTier` after a *live* controller throws `.uiUnavailable` (proves
  live), and after a *closed* one throws `.controllerClosed` (proves closed). This ordering
  (isClosed guard first) is verified at ZoneRuntimeController.swift:141.
- **`@MainActor`:** the registry is `@MainActor` (matches `ZoneRuntimeController`). The
  self-check runs on the main thread under the headless harness (`NSApplication.shared` is
  established by the other app checks; this check does not need a window). If the dispatch
  block needs `_ = NSApplication.shared` to satisfy main-actor isolation like the
  `--browser-lru-budget-check` block (:577), add it; the `--add-zone-check` block does not, so
  start without and add only if the build/run demands it.
- **NEEDS-HUMAN — the `closeOnZero == false` warm-keep semantics.** docs/23 S2 says
  `acquire`/`release` "create-if-missing / close-at-zero" and does NOT specify a warm-keep
  mode; the brief asks for a config knob but the *desired* warm behavior is ambiguous: does
  `closeOnZero == false` (a) drop the box but skip `close()` (re-acquire rebuilds — what this
  spec implements), or (b) KEEP the box warm at ref-count 0 so a fast re-acquire returns the
  SAME instance without rebuilding? Option (b) needs a way to reap warm-but-unused
  controllers (a max-warm count or an idle timer) to avoid unbounded growth — a design docs/23
  did not settle. **This spec defaults to (a)** (the conservative, docs/23-faithful choice:
  the knob only skips the `close()` side-effect on release-to-zero). If Dylan wants (b)'s
  true warm-pool, that is a follow-up with its own reaping policy + check; do not invent the
  reaper here. Implementer: assert assertion 8 to match (a) and note it in the commit body.
- **If the knob is judged unnecessary** (the registry could ship with `closeOnZero` always
  true and no user setting), the implementer may drop `ZoneRuntimeBudgetConfig` +
  `SettingsSchema` entry and hardcode `closeOnZero = true`, deleting assertions 8–9 — BUT
  this contradicts the sprint's configurable-first non-negotiable (01 §1.3), so prefer
  keeping the knob. This is flagged for the human because it is a genuine "is this config
  warranted" call the brief leaves open.
- The leader-jump nav-key collision guard is a T18 concern, unrelated here.
