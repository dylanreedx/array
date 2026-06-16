# T04 Review — `ZoneRuntimeRegistry` per-projectId ref-counted

Reviewer: adversarial, read-only. Branch `overnight/workspaces-zones`, uncommitted.

## Verdict: PASS WITH RISKS

Committable. The registry, its check, and the config knob are all genuinely
verified. One minor diagnostic-quality nit and a few flagged design choices below.

## 1. Bypass audit (#1 gate) — PASS, re-run independently

- Built + ran `--zone-registry-refcount-check` myself → GREEN (exit 0), manifest at
  `qa-runs/<ts>/zone-registry-refcount/manifest.json`.
- Created a detached worktree (HEAD + working-tree files copied in, ThirdParty symlinked),
  applied the spec's Stage-B **rebuild-always `acquire` stub**, built, ran →
  **RED: `FAIL: assertion 2: c2 === c1 (same instance — sharing guarantee)`, exit 1.**
  Confirms the check drives the REAL `acquire` path and the `===` identity assertion
  catches a rebuild. NOT a bypass.
- Second worktree mutation: real `acquire`, `release` stubbed to "remove box but never
  `close()`" → **RED, exit 1** (assertion-4 region). Confirms the `.controllerClosed`
  throw is load-bearing — "removed from dict" alone is not enough to pass.
- Worktree removed; working tree unchanged (`git status` clean of the experiment).

The check never touches `boxes` directly, never calls the factory itself for assertions;
it asserts on returned instance identity (`===`), `makeCount`, introspection
(`liveCount`/`refCount`/`isLive`/`controller`), and the controller's own post-close
behavior (`setTier` throw). This is the real `acquire`/`release` lifecycle T06/T09 will call.

## 2. Right reason — PASS

- Hand-derived assertion 2: first `acquire(P)` creates box refCount 1; second `acquire(P)`
  takes the `if var box = boxes[P]` branch, `refCount += 1` → 2, returns `box.controller`
  (same instance). `refCount(for: P) == 2`, `liveCount == boxes.count == 1`. Matches intent
  (one shared instance, two refs).
- Error-path discriminator verified in source: `setTier` `guard !isClosed`
  (ZoneRuntimeController.swift:141) fires BEFORE the `dehydrate` `guard let canvasView,
  tileSpawner else { .uiUnavailable }` (:159). So a live-but-UI-less controller throws
  `.uiUnavailable` (proves live) and a closed one throws `.controllerClosed` (proves closed).
  This is a genuine discriminator, not coincidence.
- `ZoneRuntimeController` is `final class` (ZoneRuntimeController.swift:6) so `===` is
  meaningful (a struct/`==` would hide a rebuild — rubric requirement met).

## 3. Scope — PASS

- `git diff --stat`: 17 insertions across 3 tracked files (ContinuumApp.swift +11,
  SettingsSchema.swift +5, run-matrix.sh +1), zero deletions, no adjacent refactor.
- 2 new files: `App/ZoneRuntimeRegistry.swift` (App target, co-located with
  ZoneRuntimeController), `Core/ZoneRuntimeBudgetConfig.swift` (Core). No `Package.swift`
  edit — auto-globbed, confirmed by successful `swift build`.
- Forbidden symbols untouched: grep of the ContinuumApp diff for
  `zoneRuntimeController` / `WorkspaceRuntime` / `protocol` → none. No controller internals,
  no AppKit view code, no access-level changes.
- Config wired end-to-end: `ZoneRuntimeBudgetConfig` (key + `defaultCloseOnZero=true` +
  resolver), `SettingsSchema` `.toggle` appended in `general` after Max Live Zones
  (signature `toggle(key:label:default:Bool)` matches), and default-resolution asserted in
  assertion 9 with an isolated suite (absent→true, explicit false→false, explicit true→true).
- Dispatch block correctly modeled on `--add-zone-check` (no `NSApplication.shared` needed;
  check ran headlessly). No co-author footer (nothing committed yet).

## 4. Matrix — PASS

`./scripts/run-matrix.sh --fast` → `Fast matrix passed.` New `--zone-registry-refcount-check`
present and GREEN within the run. No other check regressed.

## 5. Domain / edge probes — PASS

- Over-release safe (assertion 7): `release` `guard var box = boxes[projectId] else { return }`
  → unknown/zero is a no-op, no crash. Verified GREEN.
- Two-project independence (assertion 6): releasing Q leaves P live, `liveCount` tracks
  `boxes.count`. Correct.
- `closeOnZero == false` (assertion 8): option (a) — box dropped at zero, `close()` skipped;
  `w1.setTier` throws `.uiUnavailable` not `.controllerClosed`. Knob genuinely gates `close()`.

## Findings (minor, non-blocking)

- **F1 (diagnostics, not correctness):** Assertions 3, 4, 8 each have only a
  `catch .controllerClosed` (or `.uiUnavailable`) arm for the negative case. When the
  controller is in the WRONG closed/live state, the unexpected `HydrationLifecycleError`
  propagates UNCAUGHT out of `runZoneRegistryRefcountSelfCheck` and the dispatch block prints
  the raw `FAIL: controller UI is unavailable` instead of the intended
  `assertion 4: ...` message. Verified live in the never-close worktree experiment:
  the check still exits non-zero (matrix-correct), but the failure label is misleading.
  Quality nit only — does not affect the GREEN/RED gate.

## Risks / design choices (hoisted)

- `closeOnZero == false` implements option (a) (drop box, skip close → re-acquire rebuilds),
  NOT a true warm-pool (option b). This is the spec's documented default and the builder
  flagged it, but it remains an unsettled design call (docs/23 S2 did not specify warm-keep).
- The `qa-runs` artifact is written under `currentDirectoryPath` (repo root under the
  matrix), so each check run drops a new timestamped manifest dir — consistent with the other
  zone checks; just noting it accumulates artifacts.

## Needs human

- **closeOnZero warm-keep semantics:** confirm option (a) is the intended behavior, or
  schedule option (b) (true warm pool + reaper) as a follow-up.
- **Is the config knob warranted at all?** Spec's *Out of scope* note flags this as a
  genuine "is this config needed" call; builder kept it (configurable-first). Confirm.
- **F1 diagnostic quality:** decide whether the misleading raw-error message on a wrong-state
  failure is worth a catch-all arm that re-labels per assertion (low priority).
