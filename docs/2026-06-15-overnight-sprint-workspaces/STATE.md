# Sprint State — live ledger

Orchestrator: update this at every transition (todo → spec-written → building → review →
done / staged-for-morning / blocked), with commit sha + a one-line note. This is the
durable progress record across compaction. Branch: `overnight/workspaces-zones` (create
at bootstrap).

Legend: ⬜ todo · ✍️ spec-written · 🔨 building · 🔍 review · ✅ done · 🌅 staged-for-morning · ⛔ blocked/needs-human

| # | Task | Tag | Deps | Status | Commit | Note |
|---|------|-----|------|--------|--------|------|
| T01 | Zone model: optional projectId + name + navKey | overnight [pure] | — | ✍️ | — | spec written (exemplar) |
| T02 | Group-zone tile storage (workspace store) | overnight [pure] | T01 | ⬜ | — | spec TODO |
| T03 | ZoneHydrationOrchestrator (S1) | overnight [pure] | — | ⬜ | — | spec TODO |
| T04 | ZoneRuntimeRegistry ref-counted (S2) | overnight [pure] | — | ⬜ | — | spec TODO |
| T05 | Mutable canvas / ZoneLayer (S3) | overnight [appkit-chk] | T01 | ⬜ | — | spec TODO |
| T06 | WorkspaceRuntime shell + proxy (S4) | overnight [appkit-chk] | T03,T04,T05 | ⬜ | — | spec TODO |
| T07 | BrowserRuntimeBudget union (S5) | overnight | T06 | ⬜ | — | spec TODO |
| T08 | addZone + ambient controller (S6) | overnight [appkit-chk] | T06,T02 | ⬜ | — | spec TODO |
| T09 | switchWorkspace in-process (S7) ⚠ | overnight [appkit-chk] | T06 | ✍️ | — | spec written (exemplar) |
| T10 | Viewport-driven tier transitions (S8) | overnight | T06 | ⬜ | — | spec TODO |
| T11 | Adaptive zone bounds (union+padding) | overnight [pure+wiring] | T05 | ⬜ | — | spec TODO |
| T12 | Bulletproof restore (atomic, crash-safe) | overnight | T01,T02 | ⬜ | — | spec TODO |
| T13 | Live-session resume (terminal/browser) | overnight | T12 | ⬜ | — | spec TODO |
| T14 | Profiles/snapshots (store + apply-modes) | overnight | T12 | ⬜ | — | spec TODO |
| T15 | Sidebar view-model (pure tree) | overnight [pure] | T01 | ⬜ | — | spec TODO |
| T16 | Sidebar NSOutlineView | morning [appkit] | T15,T09 | ⬜ | — | spec TODO |
| T17 | ⌘K zone rows (jump/create) | overnight | T01 | ⬜ | — | spec TODO |
| T18 | Per-zone nav keybind + leader zone-jump | overnight | T01 | ⬜ | — | spec TODO |
| T19 | Drag-to-create-zone + move-zone gesture | morning [appkit] | T05,T11 | ⬜ | — | spec TODO |

Stretch (not critical path): S9 lock-degradation merge from `wip/con-50-zone-lock-degradation`.

## Wave order
- W1 (parallel): T01, T03, T04
- W2: T02, T05, T15 · T11 (after T05)
- W3: T06 → T07, T08, T09, T10
- W4: T12 → T13, T14 · T17, T18
- Morning: T16, T19

## Decisions log (orchestrator records playbook choices here)
- (none yet)

## Blocked / needs-human (with reasons)
- (none yet)
