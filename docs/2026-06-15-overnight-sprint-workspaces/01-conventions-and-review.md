# Conventions & Review Protocol

Status: 2026-06-15. The non-negotiable working method for every task in this sprint, the
task-file template, and how a reviewer agent verifies a finished task. This codifies how
we've been working on this codebase — read it before touching any task.

---

## 1. Non-negotiables (the bar)

1. **TDD, real-path, RED → GREEN.** Write the task's named check **first** and watch it
   FAIL, then implement the minimum to make it pass. In Swift: write the check, add
   minimal compiling stubs, see it fail on the *assertion* (not a compile error), then
   fill behavior.
2. **The check must drive the REAL path — no executor bypass.** A check that calls an
   executor / pure function directly, bypassing the input/gesture/lifecycle path it
   claims to verify, **counts as no check**. App checks synthesize real `NSEvent`s
   (`.keyDown`/`.flagsChanged`/mouse) through the real handlers
   (`handleHotkey`/`handleFlagsChanged`/`TileNSView.mouse*`) or drive the real
   runtime/persistence lifecycle, and assert **observable results**: committed world
   frames, focus scope (`focusBroker.activeSurface`), viewport, registered adapters,
   installed subviews/layers, on-disk documents. This rule exists because bypass checks
   produced ~124 "Done" tickets while the app felt hollow. (memory: `verification-doctrine`)
3. **Configurable from the start.** Every new binding / threshold / default ships with a
   persisted `UserDefaults` default + a `SettingsSchema` entry + conflict-guard coverage,
   in the same task. Nothing hardcoded; no config deferred. (memory: `tdd-and-configurable-first`)
4. **Surgical changes.** Touch only what the task names. Don't refactor adjacent code,
   reformat, or "improve" unrelated things. Remove only the orphans *your* change creates.
   Every changed line traces to the task.
5. **Matrix-gate every commit.** `./scripts/run-matrix.sh --fast` must be green before a
   commit. Register every new app check in `scripts/run-matrix.sh` AND in the
   `CommandLine.arguments` dispatch in `ContinuumApp.swift` (~line 200+).
6. **Commit message:** plain `type(scope): summary` (+ a tight body). **NEVER** add a
   `Co-Authored-By` / "Generated with" footer. (memory: `no-co-authoring`)
7. **One commit per task** (or per coherent sub-step within a task), each matrix-green.
8. **`[morning]` AppKit tasks are NOT auto-committed as Done** — implement, leave the diff
   staged with a note, hand to Dylan for the visual/feel gate + bundle rebuild.

## 2. Codebase facts you must not relearn the hard way
- **Coordinate model:** world coords, Y-**down**, top-left origin. Tile `bounds` = world
  units; `frame` = screen px (AppKit scales bounds→frame by zoom). `CanvasNSView`/
  `TileNSView` are `isFlipped`. Screen-px thresholds → world via `/ viewport.zoom`.
  `CanvasEngine.worldToScreen`/`screenToWorld`/`tileScreenFrame`; tiles are stored
  **zone-local**, converted via `CanvasEngine.worldFrame(tile:in:)`.
- **`NSView.hitTest(_:)` gets the point in the *superview's* coords** — `convert(point,
  from: superview)` before local-bounds math.
- **Stale SourceKit diagnostics are noise.** "Cannot find X in scope" / "no member" for
  symbols that exist resolve on `swift build`. The **build is authoritative** — if
  `swift build` says complete, trust it over the editor squiggles.
- **Focus:** `canvasState.lastActiveTileId` is the current tile and **persists across a
  modal** (`onAcceptedCanvasScope` only clears the focus border). `FocusBroker.openModal`
  snapshots the prior scope; `closeModal` restores it unless `tileSpawnedDuringModal`
  (entering a tile with reason `.tileSpawned` during a modal suppresses the restore).
- **Where checks live:** static funcs on `AppDelegate` in `ContinuumApp.swift` (so they
  reach `private` members) for app/real-path checks; `ContinuumRevivedCoreChecks/main.swift`
  (+ `…PaletteChecks`, etc.) for pure tables. Model new ones on the existing
  `--leader-*-check` / `--*-snap-check` shapes.
- **Dogfood (morning tasks):** quit app → `./scripts/make-app-bundle.sh --configuration
  release --output ~/Applications/ContinuumRevived.app` → `open` it.

## 3. Task-file template (every `TNN-*.md` follows this)
A task file is a contract precise enough that an agent needs no other context. Sections:

- **Title + one-line.**
- **Status:** `todo | in-progress | needs-review | done`.
- **Tag:** `overnight [pure] | overnight [appkit-checkable] | morning [appkit]`.
- **Depends on / Blocks:** task ids.
- **Goal (why):** the user-facing capability this serves, in one or two sentences.
- **Exact scope — files & symbols:** every file to touch with path + the symbols/lines,
  and an explicit **Do NOT touch** list.
- **Data / API changes:** precise type/signature deltas (copy-pasteable).
- **The check, written FIRST (the spec-as-test):** the check's name, where it's
  registered, exactly what it synthesizes through the real path, and every assertion it
  makes (this IS the acceptance spec — make it exhaustive).
- **Implementation steps:** numbered, precise, in order; note the RED→GREEN boundary.
- **Acceptance criteria:** a checklist a reviewer ticks.
- **Verification commands:** the exact shell (`swift build`; the single-check
  invocation with `CONTINUUM_PROJECT_ROOT`/`CONTINUUM_APP_SUPPORT` temp dirs;
  `./scripts/run-matrix.sh --fast`).
- **Review rubric:** task-specific things the reviewer checks + adversarial angles.
- **Out of scope / gotchas:** what to defer; coordinate/SourceKit/focus traps relevant here.

## 4. Per-task lifecycle (what an executing agent does)
1. Read this doc + the charter + the task file. Confirm `Depends on` are Done.
2. **Write the check** named in the task; register it; run it → confirm it **fails on the
   assertion** (RED). If it passes already, the task is mis-specified — stop and flag.
3. Implement the **minimum** to GREEN, following the steps and scope exactly.
4. `swift build` → run the single check → `./scripts/run-matrix.sh --fast`.
5. Self-review against the Acceptance criteria + Review rubric. Re-read your diff: every
   line traces to the task? orphans removed? configurable bits wired?
6. `[overnight]`: commit (plain message, no footer). `[morning]`: stage + write a
   handoff note (what to eyeball), do **not** mark Done.
7. Update the task `Status` and note the commit sha.

## 5. Review protocol (how an agent reviews a finished task)
A reviewer is **adversarial**: assume the task is wrong until proven right. Independent of
the implementer. Steps:

1. **Re-run the task's named check** from a clean temp env. It must pass.
2. **Run `./scripts/run-matrix.sh --fast`.** Must be green (no other check regressed).
3. **Audit the check itself for bypass** (the most important step): does it drive the
   REAL path, or does it call an executor / pure fn directly and assert on that? Trace
   the synthesized event/lifecycle to the production handler. **A green bypass check is a
   FAIL** — it proves nothing. Ask: would this check still pass if the feature were
   stubbed out? If yes, REWORK.
4. **Does it pass for the right reason?** Re-derive at least one asserted value by hand
   (e.g. the expected world frame / viewport origin / on-disk JSON) and confirm the
   assertion matches intent, not a coincidence. Check it would go RED without the change
   (mentally or by reverting one line).
5. **Diff vs. scope:** every changed line traces to the task; nothing adjacent
   refactored; orphans your change created are removed; configurable bits have a default
   + Settings entry + conflict-guard; no co-author footer.
6. **Adversarial probes for the task's domain** (the task's Review rubric lists these) —
   e.g. for a swap: does focus survive? are old adapters unregistered? does it work at
   non-origin/zoom? for persistence: kill mid-write — does reload recover?
7. **Verdict:** `PASS` (with the one-line reason it's genuinely verified) or `REWORK`
   (with the specific failing assertion / bypass / missed criterion). No "looks fine."

For `[morning]` tasks, the reviewer additionally lists **exactly what Dylan must eyeball**
(the check can't see visuals): flicker, z-order, cursor rects, layout feel, animation.

## 6. What "done" means
`[overnight]`: check + matrix green, reviewed PASS, committed. `[morning]`: check + matrix
green, reviewed PASS, **and** Dylan confirmed the visual/feel gate on the rebuilt bundle.
