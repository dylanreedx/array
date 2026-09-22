# 0721-models — explicit Claude model ids, and no anthropic under Pi

Bench: `.worktrees/0721-models`, branch `array/0721-models`, based on
`array/integration` at `2cec73ff`.

Two requests from Dylan (verbatim):

3. "i don't want claude to have 'latest' i want the model names explicitly even
   previous models"
4. "we can remove anthropic options from Pi"

## A · the Claude harness offers explicit ids

`ClaudeCLIBackend.curatedCatalogModels` / `curatedCatalogDisplayNames`
(`Sources/ContinuumRevivedCore/AgentProviders/ClaudeAgentRunner.swift`), newest
first:

| id | label |
| --- | --- |
| `anthropic/claude-opus-5` | Claude Opus 5 |
| `anthropic/claude-fable-5-1` | Claude Fable 5.1 |
| `anthropic/claude-fable-5` | Claude Fable 5 |
| `anthropic/claude-sonnet-5` | Claude Sonnet 5 |
| `anthropic/claude-opus-4-8` | Claude Opus 4.8 |
| `anthropic/claude-opus-4-7` | Claude Opus 4.7 |
| `anthropic/claude-opus-4-6` | Claude Opus 4.6 |
| `anthropic/claude-sonnet-4-6` | Claude Sonnet 4.6 |
| `anthropic/claude-opus-4-5` | Claude Opus 4.5 |
| `anthropic/claude-sonnet-4-5` | Claude Sonnet 4.5 |
| `anthropic/claude-haiku-4-5` | Claude Haiku 4.5 |

Every id is verbatim from `pi --list-models` probed on this machine 2026-09-21.
The **dated pins are deliberately omitted** (`claude-opus-4-5-20251101`,
`claude-haiku-4-5-20251001`, `claude-sonnet-4-5-20250929`): they name the same
weights as the undated id and would double the picker for no user-visible
choice. They are still pinned in the ground-truth literal in
`AgentModelConfigChecks` so the subset rule stays honest.

No routing change was needed. `ClaudeCLIBackend.routesToClaude` tests
`hasPrefix("anthropic/")` and `modelArgument(forCatalogId:)` strips the prefix,
so `anthropic/claude-opus-4-5` reaches the CLI as `--model claude-opus-4-5`,
which `claude --help` documents as accepted ("a model's full name").

### The live path

Option (i) from the brief: **the live alias scrape is deleted**.
`AgentModelCatalog.parseClaudeModelAliases(helpOutput:)` and
`apply(claudeBackendModels:)` are gone, and `probeClaudeBackend` no longer runs
`claude --help` at all. The scrape could only ever produce aliases — it kept the
slashless quoted words out of the paragraph that calls them "an alias for the
latest model" — so there was nothing it carried that the curated list cannot.
The probe is now readiness-only (`claude auth status --json`), which also drops
one subprocess off every catalogue refresh: `--strict-agent-harness-check` now
pins **3** probe launches per refresh, not 4.

### Default model

`AgentModelConfig.defaultModel` moved from the alias `anthropic/opus` to
`anthropic/claude-opus-5`. Every other reference in the tree is symbolic
(SettingsSchema, SettingsPanel, UIProbeGeometry, AgentStore/AgentRecord/
AgentInventory/RoleRegistry/PiExecutableResolution checks), so none needed
editing.

### The context-ring bonus, confirmed

`ManagedAgentTileNSView.contextWindowForCurrentModel()` falls back to
`AgentModelCatalog.shared.contextWindow(for: providerSettings.model)`, which
reads the map parsed out of pi's `~/.pi/agent/models-store.json` — keyed by
concrete ids. With an alias that lookup **could never hit**; it was dead code.
With explicit ids it can hit, and the new witness asserts exactly that shape
(`runClaudeResolvedModelContextWindowChecks` now requires every offered id to be
a legal key in a real models-store window map).

Caveat, not verified live: the fallback still needs pi's models-store on disk,
because that file is the only local source of published window sizes. On a
machine with no pi the ring still depends on the resolved id claude reports on
`system/init`, which is unchanged and remains the authority. No curated window
sizes were invented — a wrong window misreports occupancy by 5x.

## B · Pi never offers anthropic

New named policy, `PiCatalogPolicy` in
`Sources/ContinuumRevivedCore/AgentModelConfig.swift`:

- `excludedProviders: Set<String> = ["anthropic"]`
- `excludes(_:)`, `offerable(_:)`, `isRetiredSelection(model:harness:)`

Applied at **one** seam: `AgentModelCatalog.apply(listModelsOutput:)`, which is
production's only writer of pi's `liveOptions`. Chosen over `parse` so the
parser stays an honest reading of pi's table (and so the exclusion has a
positive control to contrast against), and over the serving seam so the
invariant is a property of the stored value. The models-store display-name and
context-window maps are deliberately **not** filtered — they are keyed by id and
the claude harness resolves its own `anthropic/*` windows through them.

`AgentHarnessConfig.isProviderCompatible(model:harness: .pi)` now also excludes
anthropic, so the composer rail and the settings picker filter it out even when
a QA fixture seeds one directly.

An entirely-anthropic pi reading does not blank the picker: the `isEmpty` guard
runs after the filter, so the previous options stand.

### Already-persisted anthropic-on-Pi records

The exclusion is an **offering** policy, not a capability claim — pi can still
run those models. Two carve-outs, both documented in place:

1. `AgentSupervisor.sendRefusal` accepts a model that is
   `PiCatalogPolicy.isRetiredSelection` even though it is absent from the
   harness snapshot. Without this a record that ran fine yesterday would refuse
   every prompt forever. It is absent from the picker, so moving off it is
   one-way — which is what "remove the option" means. The record is never
   re-pointed at another CLI (CLAUDE.md: selection never falls back).
2. `setProviderSettings` already validated ownership only when the model or
   harness changes, so effort edits on such a record keep working untouched —
   this is the same treatment SettingsPanel gives an incompatible stored model
   (retain it as an explicit invalid choice, never rewrite it).

Third, related: the legacy-harness rescue in `AgentSupervisor.restore()` used to
hard-code `.pi` as the one fallback for a record whose inferred harness cannot
run its model. Now that Pi does not own anthropic, an `anthropic/*` legacy record
with a stored Codex preference would have kept a dead harness. It is now a
ladder — `.pi`, then `.claudeCode`, then `.codex` — preserving the old behaviour
for `openai-codex/*` and reaching the owning harness for anthropic.

## The new witness

`Sources/ContinuumRevivedCoreChecks/AgentModelPolicyChecks.swift`,
`runAgentModelPolicyChecks()`.

**Registered next to `runBoardChecks()` near the top of
`Sources/ContinuumRevivedCoreChecks/main.swift`, NOT beside the other model
checks at the bottom.** `swift run ContinuumRevivedCoreChecks` is a KNOWN-RED
matrix leg and `expect` calls `exit(1)`, so everything registered after the
arm64 seed-1 byte pin (~line 10980) never runs in a real matrix run. That is
where `runAgentModelConfigChecks` / `runAgentModelCatalogChecks` sit today — a
pre-existing hole, see "open risks".

It asserts over the SERVED snapshot, never over source text:

- both the fallback and the post-probe `snapshot(for: .claudeCode)`: every id is
  `anthropic/<model>`, its `modelArgument(forCatalogId:)` is a concrete full
  name (`claude-` prefix plus a version number, which is exactly what
  distinguishes a full name from an alias in claude's own help text), no id or
  label contains "latest", every id carries a display name, no duplicates;
- previous models stay selectable (`claude-opus-4-5` alongside `claude-opus-5`)
  and the newest leads;
- `defaultModel` is one of the ids actually offered;
- a verbatim `pi --list-models` reading with six anthropic rows: a positive
  control that the parser carries all six through, then `apply` +
  `snapshot(for: .pi)` yields zero anthropic and every codex row in pi's order;
- an all-anthropic reading leaves the previous options standing;
- the grandfather rules, both directions, and the legacy rescue.

### Teeth (RED before, GREEN after — exact output)

1. Reintroduce `anthropic/opus`:
   `FAIL: claude-policy (fallback): opus is an ALIAS, not a model's full name — `claude --model` would resolve it to whatever ships next, and it is not a key in the context-window map`
2. Label it "Claude Opus (latest)":
   `FAIL: claude-policy (fallback): the label for anthropic/claude-opus-5 says 'latest' (Claude Opus (latest)) — a label that renames itself is the bug`
3. Drop `claude-opus-4-5` from the list:
   `FAIL: claude-policy: previous models must stay selectable alongside the newest, got ["anthropic/claude-opus-5", … "anthropic/claude-sonnet-4-5", "anthropic/claude-haiku-4-5"]`
4. `excludedProviders = []`:
   `FAIL: pi-policy: the Pi snapshot offered an anthropic model, got ["anthropic/claude-fable-5", "anthropic/claude-fable-5-1", "anthropic/claude-haiku-4-5", "anthropic/claude-opus-4-5", "anthropic/claude-opus-5", "anthropic/claude-sonnet-4-5", "openai-codex/gpt-5.6-sol", "openai-codex/gpt-5.6-luna", "openai-codex/gpt-5.3-codex-spark"]`
5. Over-broad filter (`offerable` drops everything):
   `FAIL: pi-policy: every non-anthropic row must survive, in pi's own order, got [the frozen fallback]` — i.e. the guard kept the previous options, which is the right failure mode but the wrong catalogue.

Every mutation was reverted and the section re-ran green.

## Checks changed, and why

| File | Change |
| --- | --- |
| `CoreChecks/AgentModelConfigChecks.swift` | Replaced the three-alias claude literal with the verbatim anthropic half of `pi --list-models` (dated pins included) as ground truth, plus a subset rule mirroring the codex one, plus an explicit "no alias, no 'latest' label" assertion. §2 of the catalogue section now expects the apply seam to drop the fixture's anthropic rows and gained a §2b for the exclusion. §3's pi fixture moved from anthropic ids to `google/*` — seeding Pi with anthropic is now an incoherent fixture. |
| `CoreChecks/ClaudeAgentBackendChecks.swift` | `runClaudeCatalogUnionChecks` derives the expected union from `curatedCatalogModels` instead of pinning three aliases (pinning the data re-broke this leg on every refresh, and `expect` exits). Added: every curated id routes to the claude CLI; every curated id is a legal key in a models-store window map. Narrative comments updated to say the alias era is over. |
| `CoreChecks/CodexAgentBackendChecks.swift` | Ownership matrix gained `!isProviderCompatible(anthropic, .pi)`; the union fixtures moved off `anthropic/opus`/`anthropic/sonnet` onto explicit ids and derive their expectations. |
| `CoreChecks/TranscriptRehydrationChecks.swift` | Routing fixtures moved to `anthropic/claude-opus-5` (prefix routing, so behaviour unchanged — coherence only). |
| `CoreChecks/main.swift` | Registers the new section early. |
| `App/StrictAgentHarnessChecks.swift` | The `parseClaudeModelAliases` pin is replaced by a policy assertion over the served claude snapshot; the probe-launch pin drops 4 → 3 with the `--help` probe; literals moved to explicit ids. |
| `App/AgentSupervisor.swift` (the `--managed-agent-model-spawn-check` fixtures) | `sharedModel` and its display names moved off "(latest)". |
| `App/ContinuumApp.swift` (`--claude-agent-live-check`) | Moves the agent onto `anthropic/claude-haiku-4-5`; `anthropic/haiku` no longer exists. Supervised leg — **not run here** (needs a live claude login and spends real usage). |
| `Canvas/AgentComposer/ProviderModelPicker.swift` | "pi backend must show every provider" now says Pi serves its own snapshot verbatim, and a new assertion pins that the Pi ownership filter the composer rail applies drops an anthropic id. **New step 6b** presents a real picker over the shipping `ClaudeCLIBackend.curatedCatalogModels` and asserts the pane lists all 11 in catalogue order, fits without clipping, and renders no row saying "latest". |

## Verification actually run

- `swift build` — clean.
- `swift run ContinuumRevivedCoreChecks` — the new section prints
  `agent model policy checks passed: …` and every section this ticket touched
  passes (`AgentModelConfig checks passed`, `AgentModelCatalog checks passed`,
  `AgentModelCatalog claude-union checks passed`, `AgentModelCatalog codex-union
  checks passed`, `Claude resolved-model context window checks passed`).
  The leg still exits 1 on its documented KNOWN-RED (below).
- App legs from this bench's own binary, each under a throwaway
  `CONTINUUM_PROJECT_ROOT` / `CONTINUUM_APP_SUPPORT`, all **exit 0**:
  `--provider-model-picker-check`, `--settings-panel-check`,
  `--strict-agent-harness-check`, `--managed-agent-model-spawn-check`.
- The full matrix was **not** run (out of scope for this bench).

## Open risks / not verified

1. **`swift run ContinuumRevivedCoreChecks` has TWO pre-existing reds, not
   one.** The documented KNOWN-RED is the arm64 seed-1 canonical-byte pin
   (1639 vs the 1644 this host produces). Past it there is a second, undocumented
   drift: `ClaudeAgentRunner argv` now emits a `--` separator before the prompt
   that the pinned expectation does not have (both the resume and start arms).
   Neither is this ticket's. I confirmed it by temporarily patching both pins
   locally, which made the **entire executable exit 0** — that is how I verified
   my own downstream sections — and then reverted both patches. Nothing in this
   branch changes either. Somebody should decide whether to re-baseline them;
   until then everything registered after them (including
   `runAgentModelConfigChecks`) never runs in a real matrix run, which is why the
   new witness is registered early instead.
2. **`--claude-agent-live-check` and `--component-lab-check` not run.** The first
   is supervised and spends real subscription usage; the second is KNOWN-RED.
   ComponentLab's assertion is `Set(qaModelTitles).count == modelOptions.count`
   over the id tails, which stay unique across the 11 new ids, but that is
   reasoning, not a run.
3. **No live pi/claude probe was exercised.** The probe seams are witnessed with
   injected executors and fixtures only, as the rest of this file already is.
4. **Picker growth — checked, and it holds, but only for fit.** The claude pane
   went from 3 rows to 11 and `ChoiceListView` does not scroll. `paneSize(for:
   zoom:)` sizes the pane to the TALLEST group with no cap, so nothing clips;
   `--provider-model-picker-check` step 6b now drives the real 11-id catalogue
   and passes `qaListContentFitsPane`. What is NOT asserted anywhere is that the
   resulting popover stays on screen at high page zoom near a screen edge — that
   is pre-existing behaviour for pi's much longer lists, but the claude pane is
   newly subject to it.
5. **The pi models-store still lists anthropic**, and the display-name /
   context-window maps parsed from it are deliberately unfiltered. That is load-
   bearing for the claude context ring, but it means `displayNamesSnapshot()`
   still contains anthropic keys while Pi offers none. Nothing renders from that
   union today; a future caller that treats "has a pi display name" as "pi can
   run it" would be wrong.
