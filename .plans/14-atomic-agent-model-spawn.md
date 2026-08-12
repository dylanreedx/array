# 14 — Atomic agent-model spawn

Status: **implemented and witnessed in isolated worktree; visual review pending**

## Outcome

Creating a managed agent from Cmd+K has one model decision. The tile title,
bootstrap copy, composer control, persisted agent record, and first runner all
derive from that decision before the tile is attached.

The model step also makes the two useful shortcuts explicit:

- `Default — <model>` uses the stable Settings default;
- `Recently Used — <model>` repeats the last successful Cmd+K choice when it
  differs from the default;
- the complete exact-ID catalogue remains available and searchable.

Recent use is convenience state. It never rewrites the Settings default, and a
model changed later inside an existing tile never changes what Cmd+K remembers.

## Current failure

`spawnManagedAgentFromPalette(model:)` creates and wires a default-model agent,
then mutates its record to the chosen model. Attach has already copied the
default into the composer, so the title can say GPT-5.6 Sol while the composer
still says Claude Opus 5. The persisted record and next runner use Sol; the UI
is stale.

## Implementation

1. Resolve the palette choice into `AgentModelConfig.Resolution` once.
2. Pass that resolution through `TileSpawner.spawnManagedAgent`, managed-agent
   wiring, and supervised-agent creation.
3. Remove the post-attach model mutation and title-only repair.
4. Add explicit Default and Recently Used rows above the catalogue. Persist the
   last model only after a successful spawn.
5. Extend the palette self-check to witness quick-row ordering, search, exact-ID
   dispatch, and successful-only recent persistence.
6. Add a production-flow witness proving the selected resolution reaches tile
   creation and the agent record before attach.
7. Validate the explicit choice against the live catalogue before constructing
   anything (see the section below).
8. Register the new check in `scripts/run-matrix.sh` and the committed matrix
   inventory — a witness outside the gate never runs.

## Invariants

- Model IDs remain fully qualified catalogue IDs.
- Explicit selection outranks the Settings default.
- Generic creation without a selection still uses Settings.
- Last-used state is separate from Settings and ignored if it is no longer in
  the active catalogue.
- Existing agents retain their own model; changing one tile does not change
  future spawn behavior.
- An explicit choice is validated against the catalogue AS IT STANDS AT SPAWN,
  and refused rather than substituted if it has left.

## The catalogue-validation hole the first draft opened

The old post-attach write went through `AgentSupervisor.setProviderSettings`,
which refuses a model outside `AgentModelConfig.modelOptions` — P0.10's rule,
because `--model` takes a *pattern*. Threading the resolution straight into
`spawn` bypassed that: `AgentSupervisor.spawn`/`makeAgent` validate nothing.

It is reachable. The palette's rows are the catalogue as it was when the model
step opened, and `AgentModelCatalog` refreshes on a background queue — kicked
by `enableLiveRefresh()` at startup and by `requestRefresh()` from the
onboarding panel and the tile's own provider picker. A probe landing while the
palette is up replaces `liveOptions` with only the providers pi reports as
authed, so a row can outlive its model. The old flow then left a
default-model agent and reported failure; the atomic flow would have persisted
the departed id into the record, the title, the composer, and the recent-model
shortcut.

Fixed by moving the guard AHEAD of construction:
`AgentModelConfig.resolved(selection:)` returns nil for a selection outside the
live catalogue, and `spawnManagedAgentFromPalette` refuses before any tile or
agent exists — strictly better than the old order, which built one first.
A refused spawn also records no recent model, so ⌘K cannot offer the departed
id back.

## The two source scans this change blinded

`--agent-supervisor-check` pins three `AppDelegate` signatures by EXACT line
match (`paletteAgentSpawnBranch`) because those methods need a live canvas to
run. Wrapping `wireManagedAgentTile` and `spawnSupervisedAgent` across several
lines made both scans throw — a red hidden behind the KNOWN-RED naming section
that halts the check earlier. Both declarations are back on one line with a
comment saying why, and the scan strings now pin the new parameters too. The
third, `spawnManagedAgentFromPalette`, had been reading blind since the ⌘K model
step gave it a parameter and a result; it is pinned to its real signature again.

## Verification

Run in the isolated worktree with its OWN `.build` (debug):
`swift build --disable-sandbox --product Array` — green.

- `--managed-agent-model-spawn-check` — GREEN. Teeth proven three ways: RED with
  the catalogue guard removed (`Cmd+K does not validate its selected model
  against the live catalogue before spawning`), RED against the original
  pre-fix post-attach flow, and RED with the guard kept but the atomic threading
  dropped (`Cmd+K does not pass its selected resolution into tile creation`).
- `--palette-duplicate-root-check` — GREEN: Default/Recently Used ordering,
  exact-ID search/dispatch, successful-only recent persistence, and a refused
  dispatch remembering nothing. Teeth proven: RED when the recent-model write is
  made unconditional.
- `--provider-model-picker-check`, `--agent-restore-check`,
  `--settings-panel-check`, `--unified-model-boot-check`, the palette family
  (`--palette-browser-spawn-check`, `--palette-captures-keys-over-browser-check`,
  `--palette-first-responder-restore-check`, `--palette-jump-check`,
  `--palette-zone-check`), `--spawn-placement-check`,
  `--spawn-focus-policy-check`, `--new-tile-cwd-check`, `--agent-input-check`,
  `--agent-status-check` — all GREEN.
- `ContinuumRevivedCoreChecks` and `ContinuumRevivedPaletteChecks` — GREEN.
- `--agent-supervisor-check` — the documented KNOWN-RED naming section, failing
  identically at clean HEAD and non-deterministically across runs (three
  distinct messages observed, exactly as the go-live doc records). With that one
  section temporarily stubbed, the WHOLE remainder of the check ran GREEN,
  including the per-agent provider-settings section and the three repaired
  source scans.
- `--ui-probe-check`, `--stray-window-audit-check`, `--tile-action-check`,
  `--spawn-rate-limit-check`, `--agent-inventory-wiring-check`,
  `--menu-contract-check` — GREEN under the matrix's own environment.
- App legs must be run the way the matrix runs them (`CONTINUUM_PROJECT_ROOT`
  and `CONTINUUM_APP_SUPPORT` temp dirs);
  `--palette-captures-keys-over-browser-check` hangs with no output otherwise.
- `scripts/run-matrix.sh --fast` — started twice and NOT carried to completion.
  Its inventory leg passed with the two new records (303); it was still inside
  `check-sidebar-native-ux-program.sh`'s self-test (case 31) after ~30 minutes,
  sharing the machine with another worktree's builds. The targeted legs above
  stand in; a full matrix run remains owed before merge.
- Visual review remains before merge.

## Review follow-up (second commit)

An adversarial review of the first commit defeated its own witness and found four
other holes. What changed:

1. **The catalogue guard is witnessed by BEHAVIOR now.** The first draft asserted
   that `ContinuumApp.swift` contained the string
   `AgentModelConfig.resolved(selection: model)` — which pins the call, not the
   refusal. A reviewer replaced the guard's `else { return false }` with
   `?? AgentModelConfig.resolvedFromDefaults()`, rebuilt, and the check still
   printed `passed`. ⌘K's whole spawn is now one function on the spawner,
   `spawnManagedAgentForSelectedModel`, and the check DRIVES it: a departed id
   leaves no tile, nothing on the persisted canvas, no wired record, and a
   spoken refusal naming the model. The negative scan for the old post-attach
   write is replaced by reading the composer from inside the `wire` callback —
   the tile already holds the chosen model when the record is written, so there
   is nothing left for a post-attach repair to do.
2. **The refusal speaks.** It beeped and said nothing before: ⌘K dispatches and
   closes whatever the result, so picking a departed model did nothing at all,
   visibly or on stderr. `announceRefusal` is injectable so the check can
   capture the message instead of beeping.
3. **Invariant 3 has a witness.** `resolved(selection: nil)` RETURNS
   `resolvedFromDefaults()` by construction, so comparing them could not fail.
   The check writes a model into its own defaults suite and asserts the spawned
   tile's title and resolution against that literal.
4. **Reveal-from-inbox is titled from the agent's record.** Deleting
   `renameManagedAgentTileForModel` left that path with no repair: it spawned
   from Settings while `attach` put the record's real model in the composer, so
   a revealed agent's tile read "Claude Opus 5" over a composer saying
   "GPT-5.6 Sol". `spawnManagedAgentForExistingAgent(_:supervisor:)` takes the
   supervisor, so the call site cannot omit the lookup, and the check drives it
   with a real record.
5. **No check writes the owner's model choice.** `LaunchProfilePalette` takes its
   defaults injected; `--palette-duplicate-root-check` uses a private suite, and
   asserts at the end of its body — before any restoring `defer` — that the
   standard domain's model/recents keys are untouched. `check-app-bundle.sh` runs
   that leg inside the app bundle, so `--channel prod` had been rewriting the real
   configured agent model for the length of the run. (A per-run suite still leaves
   an EMPTY plist in the real `~/Library/Preferences`: `removePersistentDomain`
   empties the domain, and cfprefsd rewrites the file after the process exits —
   measured, and not fixable by unlinking it. Unique-per-run names are kept anyway,
   as the other QA suites in this target do, because two worktrees can run one leg
   at the same moment and a shared suite would make the gate flaky.)
6. **`--managed-agent-model-spawn-check` moved up the matrix**, ahead of the
   KNOWN-RED `--palette-first-responder-restore-check`: the script is
   `set -euo pipefail` with bare calls, so it aborted before ever reaching the
   new leg.

Two corrections to the first commit's claims: `wireManagedAgentTile`'s scan
belongs to `--agent-restore-check` (`runAgentRestoreChecks`), not
`--agent-supervisor-check`; and of the three `paletteAgentSpawnBranch` scans, only
`spawnManagedAgentFromPalette` was actually stale in committed history (since
`091eeae`) — `wireManagedAgentTile` and `spawnSupervisedAgent` both matched at
`44fbe73`, verified by replaying the scan against those revisions.
