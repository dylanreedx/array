# Sprint State — live ledger

Orchestrator: update this at every transition (todo → spec-written → building → review →
done / staged-for-morning / blocked), with commit sha + a one-line note. This is the
durable progress record across compaction. Branch: `overnight/workspaces-zones` (create
at bootstrap).

Legend: ⬜ todo · ✍️ spec-written · 🔨 building · 🔍 review · ✅ done · 🌅 staged-for-morning · ⛔ blocked/needs-human

| # | Task | Tag | Deps | Status | Commit | Note |
|---|------|-----|------|--------|--------|------|
| T01 | Zone model: optional projectId + name + navKey | overnight [pure] | — | ✅ | 6aa283d | built+reviewed PASS (0 iters); navKey config split→T18 (confirm) |
| T02 | Group-zone tile storage (workspace store) | overnight [pure] | T01 | ✅ | 390079a | built+reviewed PASS (0 iters); storage-shape choice flagged |
| T03 | ZoneHydrationOrchestrator (S1) | overnight [pure] | — | ✅ | 0b39c8c | built+reviewed PASS (0 iters); planner wiring deferred→T06/T10 |
| T04 | ZoneRuntimeRegistry ref-counted (S2) | overnight [pure→app] | — | ✅ | 974c2fa | built, reviewed PASS-WITH-RISKS (0 iters); closeOnZero design knob flagged |
| T05 | Mutable canvas / ZoneLayer (S3) | overnight [appkit-chk] | T01 | ✅ | 70a77e1 | built PASS-WITH-RISKS; storage-shape B + morning visual gate flagged |
| T06 | WorkspaceRuntime shell + proxy (S4) | overnight [appkit-chk] | T03,T04,T05 | ✅ | 93c68f4 | built PASS-WITH-RISKS; 3 carry-fwds done (budget+chrome probed; shape-B→T09); windowWillClose-order/attachUI risks→🔴 |
| T07 | BrowserRuntimeBudget union (S5) | overnight | T06 | ✅ | 4ba7eac | built PASS-WITH-RISKS; focus-mode protect regression→🔴(R1); cross-zone full after T08(R2) |
| T08 | addZone + ambient controller (S6) | overnight [appkit-chk] | T06,T02 | ✅ | a18b1ac | built PASS-WITH-RISKS; +fixer (R2 lock + R3 tile-routing, RED-confirmed); $HOME-write design→🔴 |
| T09 | switchWorkspace in-process (S7) ⚠ | overnight [appkit-chk] | T06 | ✅ | 1818510 | built PASS-WITH-RISKS (1 iter); HIGH: prod switch INERT (throwing boot registry)→T20+🔴; shape-B descriptor-active→🔴 |
| T10 | Viewport-driven tier transitions (S8) | overnight | T06 | ✅ | 1d7924a | built PASS-WITH-RISKS; +fixer (debounce-coalescing + planner-pin checks, RED-confirmed); T09 ref-count leak fixed; live gated on T20 |
| T11 | Adaptive zone bounds (union+padding) | overnight [pure+wiring] | T05 | ✅ | 16806b1 | built PASS-WITH-RISKS; legacy chrome only — ZoneLayer-chrome gap→T06 |
| T12 | Bulletproof restore (atomic, crash-safe) | overnight | T01,T02 | ✅ | ddd0795 | built PASS-WITH-RISKS; 14-assertion crash-safe check; fsync in SHARED AtomicWriter (NH1) + no live autosave caller yet (NH2)→🔴 |
| T13 | Live-session resume (terminal/browser) | overnight | T12 | ✅ | (T13) | built (2 iters)+fixer (A7 bypass + A2 bound closed, RED-confirmed); OSC-7 real-shell-emit dep + cold-reboot blob + A6 replay→🔴 |
| T14 | Profiles/snapshots (store + apply-modes) | overnight | T12 | ✍️ | — | spec written (review folds into build) |
| T15 | Sidebar view-model (pure tree) | overnight [pure] | T01 | ✅ | b3728fc | built PASS-WITH-RISKS (0 iters); ?? "" vs "Project" fallback to ratify before T16 |
| T16 | Sidebar NSOutlineView | morning [appkit] | T15,T09 | ✍️ | — | spec written (review folds into build) |
| T17 | ⌘K zone rows (jump/create) | overnight | T01 | ✍️ | — | spec written (review folds into build) |
| T18 | Per-zone nav keybind + leader zone-jump | overnight | T01 | ✍️ | — | spec written (review folds into build) |
| T19 | Drag-to-create-zone + move-zone gesture | morning [appkit] | T05,T11 | ✍️ | — | spec written (review folds into build) |
| T20 | ⚠Wire boot WorkspaceRuntime real per-project controller factory | overnight [appkit-chk] | T06(debt) | ⛔ | — | NEEDS-HUMAN design (T09 review): boot registry throws on acquire → add-zone/switch INERT in live app; keystone built+verified but NOT live until this. Stub: T20-wire-boot-registry-factory.md |

Stretch (not critical path): S9 lock-degradation merge from `wip/con-50-zone-lock-degradation`.

## Wave order
- W1 (parallel): T01, T03, T04
- W2: T02, T05, T15 · T11 (after T05)
- W3: T06 → T07, T08, T09, T10
- W4: T12 → T13, T14 · T17, T18
- Morning: T16, T19

## Decisions log (orchestrator records playbook choices here)
- 2026-06-15 Phase 0: branch `overnight/workspaces-zones` created off `main @ 6685b88` (clean tree).
- 2026-06-15 Phase 1: dispatched spec-gen Workflow (writer → adversarial reviewer/fixer per spec) for T02–T08, T10–T19.
- Ignoring the foreign PreCompact hook (QA-Round-5 / selectus / conductor / 35-min loop) per standing instruction — not this project.

## Blocked / needs-human (with reasons)
- (none yet)
