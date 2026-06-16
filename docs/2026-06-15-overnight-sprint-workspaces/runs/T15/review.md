# T15 Review — Sidebar view-model (REVIEWER, adversarial)

Verdict: **PASS WITH RISKS**

Reviewed: `Sources/ContinuumRevivedCore/SidebarTree.swift` (new),
`Sources/ContinuumRevivedCoreChecks/main.swift` (+177, appended `do{}`), against
`docs/2026-06-15-overnight-sprint-workspaces/T15-sidebar-view-model.md`. Read-only; no edits
committed. Temporary mutations were applied to the (untracked) builder to prove RED, then
restored byte-identical (`diff -q` IDENTICAL; key lines re-grepped).

## 1. BYPASS gate (#1) — PASS
The check drives the **real production path**: it constructs a synthetic `Registry` + a
`[UUID: WorkspaceDocument]` map and calls the production
`SidebarTreeBuilder.build(registry:documents:)`, then asserts field-by-field on the
**returned tree** (`tree.workspaces[...].zones.map(\.zoneId)`, `...name`, `...color`, etc.) —
not on intermediate locals and not on a re-implemented comparator. For a pure-model task this
derivation table IS the real path (spec R1).

Would it pass if the feature were stubbed/removed? **No.** Proven by re-running against the
spec's empty-tree stub (`build` → `SidebarTree(workspaces: [])`):
`FAIL: sidebar tree: expected 4 workspace rows, got 0` (assertion 1). The check is genuinely
load-bearing.

## 2. RIGHT REASON — PASS (re-derived by hand + mutation-tested)
- **Assertion 3 (z-order) re-derived:** WS_A storage `zones=[A1,A2]`, `zoneZOrder=[A2,A1]`.
  `zoneZOrder.enumerated()` → {A2:0, A1:1}; ascending-by-index sort → `[A2, A1]`. Assertion
  expects `[zoneA2Id, zoneA1Id]` — matches, and is the **reverse of storage**, so it proves
  z-order (not array order) drives the sort. Correct, not coincidental.
- **Assertion 8 mutation test:** removed the `uuidString` tiebreak → RED
  `got ["…C2", "…C1"]` (storage order), assertion demands `["…C1", "…C2"]`. Tiebreak path
  provably runs; fixture stores WS_C zones in trap order `[C1(=…C2), C2(=…C1)]` so a missing
  tiebreak fails (spec R4 satisfied).
- **Assertion 4 mutation test:** replaced backfill with `placement.name` → RED
  `project zone name must be backfilled…, got ''`. Confirms the project zone's stored name is
  `""` and the registry name (`"continuum-revived"`) differs, so the backfill is genuinely
  exercised (spec R2 satisfied).
- **R3 (group vs project divergence):** assertion 4 (project → backfilled) AND assertion 5
  (group → stored `"Scratch"`, no backfill) both present. Branch covered.

## 3. SCOPE — PASS
- `git status`: only `Sources/ContinuumRevivedCoreChecks/main.swift` modified,
  `Sources/ContinuumRevivedCore/SidebarTree.swift` new, plus the `runs/T15/` docs dir. Nothing
  else.
- Do-NOT-touch list respected: no `WorkspaceDocument.swift` / `Registry.swift` /
  `RegistryStore.swift` / `WorkspaceStore` / `ContinuumApp.swift` / `switchWorkspace` /
  `scripts/` / `Package.swift` edits (grep over `git diff --name-only` = none).
- New Core file has **no AppKit/SwiftUI/Cocoa import** (only `import Foundation`).
- All four types are `Equatable, Sendable` with the exact shape from the spec.
- No new `UserDefaults` / `SettingsSchema` / threshold / binding — configurable-first is N/A
  by spec (pure projection). Correct; nothing wired because nothing needed.
- No orphans (new file). No commit made; no co-author footer in any artifact.
- Builder iterates `registry.workspaces` (array) at SidebarTree.swift:43 and *looks up* into
  `documents` — the determinism trap (do not iterate the dict) is honored structurally.

## 4. MATRIX — PASS
`./scripts/run-matrix.sh --fast` → **"Fast matrix passed."** Core checks
(`ContinuumRevivedCoreChecks passed`) green; no other check regressed. Standalone Core run via
the spec's temp-env invocation also green.

## 5. Edge-case probes (spec rubric) — PASS
- Assertion 7 (R-fallback): WS_B `zoneB1` uses `projGhostId` absent from `registry.projects` →
  `name == ""`. Verified green; the `?? ""` path is exercised.
- Assertion 9: WS_D absent from `documents` → `zones.isEmpty`; builder `else { zones = [] }`,
  no crash. Verified.
- Assertion 10: `Registry.empty()` + `[:]` → empty tree. Verified.
- Fixture model signatures all match production inits (`ZonePlacement`, `WorkspaceDocument`,
  `WorkspaceEntry`, `ProjectEntry`, `Registry`, `RegistrySettings`) — compiles + runs.

## Confirmed defects
None.

## Risks (named, not blockers)
- **R-FALLBACK-LITERAL (design, NEEDS-HUMAN):** This task uses `?? ""` for an unresolved
  project zone; the live canvas backfill (`ContinuumApp.loadActiveZoneRenderModels`,
  ContinuumApp.swift:3569) uses `?? "Project"`. The divergence is **intentional per spec R5**
  (T16 owns empty-name presentation), and I verified the canvas literal really is `"Project"`,
  so the two are knowingly different. A human should ratify "`""` here vs unify on `"Project"`"
  before T16 consumes the tree. Low risk; one-line change either way.
- **R-ASSERTION-11-WEAK (acknowledged in spec):** assertion 11 (`build == build`) is a weak
  determinism net — intra-run dict iteration is stable, so it would NOT catch a top-level
  built by iterating `documents`. Mitigated: top-level order is pinned by assertion 1
  (array-order) and zone order by assertions 3/8. No action needed; flagged for completeness.
- **R-TIEBREAK-COMPARATOR-SHAPE (minor, latent):** the zone comparator returns
  `a.zoneId.uuidString < b.zoneId.uuidString` only when `ia == ib`, which is a valid
  strict-weak ordering. When the tiebreak was *removed* during my mutation test, the resulting
  comparator (`return ia < ib`) violates strict-weak ordering for equal-index elements;
  `sorted` happened to preserve storage order here, which is what made assertion 8 fire. The
  shipped builder is correct (valid total order); noting only that assertion 8's RED relies on
  Swift's `sorted` behavior for the *broken* variant, not a guaranteed contract. Does not
  affect the green path.

## Unverified
- I did not exhaustively diff the restored `SidebarTree.swift` against the builder's *exact*
  original bytes beyond re-grepping the load-bearing lines (tiebreak + backfill + `Int.min`)
  and confirming green after restore; the file is untracked so there is no git baseline to diff
  against. The restore is from a backup taken at review start, confirmed IDENTICAL by `diff -q`.
- Full (non-fast) matrix / app-bundle check not run (spec's verification list is `--fast`
  only).
