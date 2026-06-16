# T14 Review — Profiles / snapshots (re-dispatch attempt 1)

Reviewer: Opus 4.8 (1M). Branch: overnight/workspaces-zones. READ-ONLY.
Verdict: **PASS WITH RISKS**

## Summary

The store + two apply recipes + config are real, disk-driven, and non-vacuous (RED-probed
below). The builder's central deviation — making `captureProfile(.template)` a no-op and
removing the two Settings entries (reviewer-recommended "option (c)") — is **architecturally
justified and correctly disclosed**, but it means the spec's headline feature (the
snapshot-vs-template strip distinction) ships with **zero behavioral effect**. That is a
named, accepted risk, not a hidden one. Matrix green; build clean; scope tight.

## 1. BYPASS audit (#1 gate)

Re-ran the check myself: `--workspace-profile-check` → `ContinuumRevivedWorkspaceProfileChecks
passed` EXIT 0; `ContinuumRevivedCoreChecks passed`; `./scripts/run-matrix.sh --fast` →
`Fast matrix passed.`

**RED probes (transient edits to WorkspaceProfileStore.loadProfile, reverted; tree clean after):**
- Corrupted a layout field on load (`zones[0].name = "CORRUPT"`) → app check `FAIL: assertion 1`,
  Core `FAIL: WorkspaceProfile Codable round-trip` (EXIT 1). Proves assertions 1/2/3 assert
  observable disk-loaded layout, not the in-memory echo.
- Removed `validateSchema` call on load → app check `FAIL: assertion 10: loadProfile(P3)
  throws unknownFutureSchema` (EXIT 1). Proves assertion 10 exercises the real throw.

**Real-path verdict, per sub-feature:**
- Store save/load/list/delete + future-schema guard (assertions 1, 9, 10): REAL — drives
  `WorkspaceProfileStore` through `AtomicWriter`, reads files back via `fileExists` /
  `listProfiles` / `loadProfile`. Cannot be stubbed.
- Apply recipes (assertions 5/6/7/8): REAL — reads `WorkspaceStore.load()` and
  `RegistryStore.load()` from disk; asserts registry count unchanged (5: ==1) vs incremented
  (7: ==2) and W0 untouched after instantiate (7) — restore-over vs instantiate-as-new are
  observably distinguished. Assertion 6 proves the backup by an actual `canvas.*.json` file
  in the backups dir. Cannot be stubbed.
- Config resolvers (assertion 11): REAL — real `UserDefaults` suite; default/override/bogus.
- **Snapshot-vs-template distinction (assertions 2/3/4/8 strip semantics): BYPASSED.**
  `captureProfile(.template)` returns `capturedDocument = document` verbatim
  (WorkspaceProfileStore.swift:130) — byte-identical to `.snapshot`. The check would pass
  unchanged if the `.template` branch were deleted. Assertion 4 was inverted from the spec's
  `template.document != srcDoc` to `template.document == srcDoc` (ContinuumApp.swift:10460).
  This is the spec's headline feature shipping as dead config. **Disclosed by the builder; see
  risk R1 for why it is justified.**

## 2. RIGHT REASON (hand-derived value)

Rubric asks to recompute the template viewport. `srcDoc.viewport = CanvasViewport(x:10, y:20,
zoom:1.5)` (ContinuumApp.swift:10373). The template strip leaves the document untouched, so
`loadedTmpl.document.viewport` round-trips to `(10,20,1.5)`. Assertion 3 asserts
`loadedTmpl.document.viewport == srcDoc.viewport` (ContinuumApp.swift:10448) — matches intent,
and the RED probe confirms it would fail on a corrupted document. Correct, not coincidental.

## 3. SCOPE

- Diff is 401 insertions, 0 deletions, across exactly the spec's named files + the 2 new files
  (WorkspaceProfileStore.swift 195 lines, WorkspaceProfileConfig.swift 20 lines). No adjacent
  refactor.
- Protected files NOT touched: `AtomicWriter`, `WorkspaceStore.swift`, save-controller,
  `ProjectStore`, sidebar/OutlineView — confirmed via `git diff --name-only` (none present).
  The store reuses `AtomicWriter.write/read` (WorkspaceProfileStore.swift:145,150) — no
  hand-rolled JSON or backup logic; backups dir is `profilesDirectory/backups`
  (WorkspaceProfileStore.swift:66), separate from WorkspaceStore's per-workspace backups per
  the spec gotcha.
- Hermeticity correct: every store in the check is constructed with `applicationSupportDirectory:
  appSupport` (the temp dir); `WorkspaceProfileStore` takes the same first/only-optional param
  shape as `WorkspaceStore`/`RegistryStore`.
- Configurable bits: `WorkspaceProfileConfig` keys + resolvers exist and are RED-proven on
  bogus input (assertion 11). **But the two Settings entries were removed** and the
  `expectedKeys` conflict-guard no longer references them — so the spec's "both keys appear in
  SettingsSchema general section AND in expectedKeys" acceptance item is intentionally NOT met
  (see risk R2). The unique-keys assertion still holds (no collision). No dangling references
  to the removed keys in app/settings code (grep clean).
- App-target change is exactly two surgical hunks: the dispatch block (~:869) and
  `runWorkspaceProfileSelfCheck` (~:10333). No co-author footer (uncommitted; orchestrator
  commits).

## 4. MATRIX

`./scripts/run-matrix.sh --fast` → `Fast matrix passed.` No other check regressed.
Build: `swift build` clean.

## 5. Domain / edge probes

- listProfiles ordering (assertion 9): sorts by createdAt then id; junk `notjson.json` skipped
  via try?-decode (WorkspaceProfileStore.swift:175-179). Ordering load-bearing constraint
  respected — junk written before assertion 9, P3 (future-schema) written after.
- Future-schema (assertion 10): `validateSchema` throws only when `schemaVersion >
  currentSchemaVersion`; correct version(2)/supported(1) payload asserted.
- listProfiles does NOT call validateSchema per-entry — a future-schema file would pollute the
  list. The check honors the spec's mandated 9-before-10 ordering, so this is not exercised as
  a bug, but it is a latent behavior (the spec documents it as the chosen design).

## Confirmed defects

None blocking.

## Risks (named, accepted — see needsHuman for the decision owner)

- **R1 — headline feature is dead config.** `captureMode` snapshot/template has no behavioral
  effect: WorkspaceDocument is layout-only (verified: fields are schemaVersion/viewport/zones/
  zoneZOrder/lastActiveZoneId/groupZoneTiles; `Tile` inside groupZoneTiles carries only
  `runtimeRef` (kind+id pointer) + `TileMetadata` (launch config), NOT live session-state).
  T13 session-state (`scrollback: String?` on TerminalSessionDescriptor, `interactionState:
  Data?` on BrowserTile) lives in ProjectStore sibling stores keyed by tile id. The spec's
  template-strip assumed session-state ON WorkspaceDocument, which is false. Building the real
  strip requires a session-state bridge that reaches into the sibling stores and embeds session
  data in the profile — i.e. **new capture**, which the spec's "Do NOT touch / Do not add new
  capture" guard forbids. So option (c) is the only spec-compliant resolution. The risk: a
  later session-bundle task must revisit `captureProfile`, re-add the Settings entries +
  expectedKeys, and flip assertion 4 back to `!=`.
- **R2 — acceptance criteria not fully met.** Two spec acceptance items are intentionally
  unmet: (a) "captureProfile(.template) strips session on every zone — asserted by !=" and
  (b) "both WorkspaceProfileConfig keys in SettingsSchema + expectedKeys." Both are downstream
  of R1. The build report self-marks these `[~]`. This is a deliberate scope reduction, not an
  oversight.
- **R3 — spec/architecture mismatch is a planning defect, not a build defect.** The T14 spec
  was written against an assumed (never-built) data shape. The same mismatch will recur in any
  task that assumes session-state on WorkspaceDocument. Worth a note in the sprint's carry-
  forward so dependent tasks (T16 sidebar "Save as profile") don't inherit the false assumption.

## Unverified

- Did NOT independently re-derive the AtomicWriter backup-naming/retention behavior; relied on
  assertion 6 (>=1 `canvas.*.json` in backups dir) + the fact that AtomicWriter is unchanged.
- Did NOT exercise the app through the real UI (no orchestrator/UI ships in T14 by design); the
  two apply recipes are proven only as check-resident call sites against disk, as the spec
  intends.

## Needs human (Dylan)

- **Accept or reject option (c).** The headline snapshot/template feature ships inert. The
  builder + prior reviewer chose to scope T14 to layout-only and defer the session-state bridge.
  This is defensible given the "Do not add new capture" guard, but it means T14 delivers the
  store + apply recipes + config plumbing WITHOUT the differentiating capture behavior. Confirm
  this is the intended landing, or re-scope to add the session-bundle bridge (which expands T14
  past its stated boundary).
- **Decide where the session-bundle bridge lands** (a follow-up task vs widening T14) and ensure
  the carry-forward records that WorkspaceDocument is layout-only so future profile/sidebar work
  doesn't re-assume session-state on it.
