# Command Center Redesign — Implementation Handoff

Snapshot: 2026-08-10, branch `array/integration`, observed HEAD `825bbe8`.

Current operating constraint from Dylan: `/Applications/Array.app` is live and
in use. Do not quit, signal, replace, relaunch, or otherwise touch that process,
its production state, or its project root. This continuation used only builds
and standalone `.build/debug/Array --*-check` processes with isolated
`CONTINUUM_APP_SUPPORT` directories; it did not launch or manage the installed
app. Do not run `scripts/dev-app.sh` while this constraint remains current.

Source design: [06-command-center-redesign.md](06-command-center-redesign.md).

This document is the compaction/resume point for the first implementation
slice. Read the source design first, then this handoff. Do not rely on chat
history.

## Outcome currently implemented

`Cmd+K` still dispatches through the existing `LaunchPaletteRow` and
`LaunchPaletteAction` identities, but the visible menu now uses a separate
product-facing command-center presentation layer.

Implemented:

- concise entity-first titles and subtitles instead of raw enum copy;
- categorized results: Recent, Agents & Tiles, Workspaces & Projects, Actions,
  Create, and Developer;
- a curated empty-query home capped at 12 items;
- typed search across legacy tokens plus cleaned titles, subtitles, and aliases;
- exact/prefix ranking with category order derived from ranked results;
- stable dispatch identity after presentation cleanup;
- rich tile destinations carrying tile kind, workspace/zone context, managed
  agent name, model id/display name, operational status, and attention reason;
- a real Needs You section populated from the supervisor's unresolved approval
  or user-input request (not from unread/activity heuristics);
- model, status, context, and attention metadata participating in search without
  becoming command identity (so searching `gpt 5.6` finds the named session);
- safe, deduplicated recents capped at five, with destructive and stale entries
  excluded;
- outcome-aware recents: palette callbacks return synchronous success, refused
  or cancelled selections do not mutate persistence, and asynchronous relaunch
  actions are not claimed as successful recents;
- shallow New Agent drill-forward: Return advances inside the same card to the
  live, backend-filtered exact model catalogue; model names remain primary,
  provider and fully-qualified id remain metadata, Escape returns to the root
  with its query restored, and successful creation records the parent Agent
  action rather than the intermediate model choice;
- a 660-point floating AppKit command-center surface with section headers,
  46-point result rows, icons, a bezel-free search field, a 0.5-point boundary,
  rounded corners, and a soft shadow;
- keyboard movement that skips section headers and disabled rows;
- content-aware height, 660-point width cap, upper alignment, and host-bound
  clamping down to a 360-by-260 window;
- Solid, Frosted, Glass, and Custom appearance resolution;
- Frosted as the default at 84% background opacity;
- Reduce Transparency forcing Solid and Increase Contrast strengthening the
  background scrim;
- live response to macOS accessibility display-option changes;
- focused surface witnesses for 46-point result density, non-selectable section
  headers, Solid/Frosted/Glass behavior, and light/dark token repainting;
- Appearance settings for the preset and bounded custom opacity;
- a generic bounded numeric settings slider with declarative visibility; Custom
  opacity is hidden for Solid/Frosted/Glass, appears for Custom, displays a
  percentage, and writes a clamped numeric preference live;
- deterministic CoreChecks and expanded palette self-check coverage.

The old `LaunchPaletteModel.makeRows` and `filterRows` APIs intentionally remain
compatible because app checks and other callers depend on their ordering and
raw `displayName` values.

## Intended isolated change set

Only these files belong in the command-center commit:

- `.plans/06-command-center-redesign.md`
- `.plans/06-command-center-redesign-handoff.md`
- `Sources/ContinuumRevived/App/LaunchProfilePalette.swift`
- `Sources/ContinuumRevived/App/SettingsPanel.swift`
- the command-center hunks in `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`
- `Sources/ContinuumRevivedCore/CommandCenterAppearanceConfig.swift`
- `Sources/ContinuumRevivedCore/SettingsSchema.swift`
- `Sources/ContinuumRevivedCore/SettingsField.swift`
- `Sources/ContinuumRevivedCoreChecks/CommandCenterChecks.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`

Do not stage other dirty or untracked files. In particular, the observed
changes in `UIProbeGeometry.swift`, `AgentComposerView.swift`,
`ComposerTextView.swift`, `ComposerPasteboardIntake.swift`, plans 07/08/09,
brand, ticket STOP files, archives, and website files belong to other
concurrent work. At this snapshot every observed `ContinuumApp.swift` diff hunk
belongs to the command center: enriched rows, palette callback wiring,
`spawnManagedAgentFromPalette`, `performPaletteAction`, and the synchronous
success seams used by truthful recents. Reinspect before staging because this
is a shared worktree and that fact can change.

No command-center files were staged. The attempted isolated commit was blocked
because this agent session mounted `.git` read-only and could not create
`.git/index.lock`.

Resume attempt on 2026-08-10: the exact eleven-path `git add` was retried after
fresh focused verification and failed again with `Unable to create
.git/index.lock: Operation not permitted`. Nothing was staged or committed.

## Verification already witnessed

These passed from freshly rebuilt products before the handoff:

```text
CommandCenterChecks passed
ContinuumRevivedPaletteChecks passed
ContinuumRevivedPaletteFirstResponderRestoreChecks passed
Build of product 'Array' complete
```

The focused commands are:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/array-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/array-swiftpm-cache \
  swift build --disable-sandbox --product ContinuumRevivedCoreChecks
.build/debug/ContinuumRevivedCoreChecks --command-center-check

env CLANG_MODULE_CACHE_PATH=/private/tmp/array-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/array-swiftpm-cache \
  swift build --disable-sandbox --product Array

qa_root=$(mktemp -d /private/tmp/array-command-center.XXXXXX)
CONTINUUM_APP_SUPPORT="$qa_root" \
  .build/debug/Array --palette-duplicate-root-check
CONTINUUM_APP_SUPPORT="$qa_root" \
  .build/debug/Array --palette-first-responder-restore-check
```

Latest continuation witness (2026-08-10): after adding rich destinations and
Needs You, a fresh CoreChecks build passed `--command-center-check`; a fresh
Array debug build completed; and both palette app checks above passed from an
isolated `/private/tmp` app-support directory. The Core witness now covers
approval/input presentation, model-metadata search, stable dispatch identity,
and the 12-item cap when more than 12 agents need attention.

A later continuation on the same date changed selection callbacks to report a
truthful synchronous result. The palette self-check now proves a refused
profile selection writes no recent and an accepted selection does. It also
probes the real command-center surface for responsive bounds, upper placement,
46-point rows, Solid/Frosted/Glass opacity and blur, and light/dark repainting.
The Array debug build and both focused palette checks passed afterward.

The same continuation replaced the raw custom-opacity text field with a generic
bounded slider field and a declarative visibility condition. Fresh CoreChecks
passed `--command-center-check`; a fresh Array debug build completed; and the
standalone isolated `--settings-panel-check` passed, including hidden-by-default,
Custom-visible, numeric persistence, clamping, and re-hiding after leaving
Custom.

The latest continuation added the shallow New Agent model step and rebuilt both
focused products. `--command-center-check`, `--palette-duplicate-root-check`,
`--palette-first-responder-restore-check`, and `--settings-panel-check` all
passed. The palette witness covers forward navigation, child search, Escape
back with root-query restoration, exact fully-qualified model dispatch, and
parent-action recency. It also pins the friendly fallback title (`GPT-5.6 Sol`)
so a temporarily unavailable live display-name catalogue cannot leak the raw
model suffix into primary copy. Every app check used a fresh isolated `/private/tmp`
`CONTINUUM_APP_SUPPORT` directory; no installed app was launched or managed.

A resumed session rebuilt both products once more and passed
`--command-center-check`, `--palette-duplicate-root-check`,
`--palette-first-responder-restore-check`, and `--settings-panel-check`. The
Array product was built but never launched except as those short-lived isolated
self-check processes. The production app, process, state, bundle, and project
root were not addressed.

Always rebuild the checks product immediately before trusting it. Multiple
agents share `.build`; after another build, a later invocation of the focused
flag reached the old full CoreChecks path and failed on the sandbox-blocked tmux
probe. The earlier focused witness was green after its own explicit rebuild.

The unfiltered CoreChecks executable is not a useful witness in this sandbox:
it reaches an unrelated tmux socket probe and aborts with
`ConnectionError.probeFailed`.

## Historical preview state

Before Dylan imposed the current live-app constraint, `scripts/dev-app.sh` was
used for the dev preview. The standard Desktop preview target could not be
replaced because this filesystem profile cannot write
`~/Desktop/Array Dev.app`. The script may have quit the previously running
Desktop preview before failing to replace it.

A dev-channel bundle was successfully assembled at:

```text
/private/tmp/Array Command Center Dev.app
```

It is pinned to `/private/tmp/array-command-center-scratch`, but LaunchServices
returned `kLSNoExecutableErr` even though the executable exists. Therefore no
visual dogfood pass has been completed in this session. Never use or modify the
prod app in `/Applications`.

## Known gaps and risks

This is a substantial first slice, not the entire source design.

1. **No full matrix result.** Targeted witnesses and the Array debug build are
   green; the full matrix was not run.
2. **Visual tuning is unwitnessed.** Density, upper-third placement, shadow,
   selection contrast, and the 84% Frosted default still need inspection over
   bright and dark canvas regions.

## Next work, in order

### 1. Land the isolated first-slice commit

This session cannot mutate `.git`, so the commit remains blocked here. In a
session with a writable repository index, re-run the focused witnesses after
any concurrent build, inspect only the files and partial hunks listed above,
and commit without staging unrelated work. Confirm the commit contains Dylan's
identity and no attribution trailers.

### 2. Keep drill-forward deliberately shallow

The New Agent → model step is implemented. Extend the stack only if dogfood
finds another coherent parameter choice that currently causes modal churn. Do
not add visible modes, tabs, a preview pane, or a permanent inspector.

### 3. Defer preview lifecycle work while Array is live

Do not run `scripts/dev-app.sh`, use `open`, signal either Array process, or
replace any app bundle while Dylan's live-app constraint remains current. A
future session explicitly cleared to manage the dev preview can inspect empty,
typed, long-title, disabled-row, light, dark, Solid, Frosted, Glass, Reduce
Transparency, and Increase Contrast states on small and large windows.

Make visual tuning changes only after that pass. The most likely first
adjustments are height calculation, upper-third positioning, section spacing,
and the Frosted scrim strength.

### 4. Run the broader gate and dogfood

After the probes and dynamic data are complete, run the relevant matrix legs,
then use only `Cmd+K` for a working session. Verify workspace switching, agent
and tile destinations, zone navigation, common creation, safe recents, focus
restoration, and stale-destination cleanup.

## Resume checklist

1. Read plan 06 and this file.
2. Inspect `git log -5 --oneline` because concurrent agents advanced the branch
   during this implementation.
3. Inspect `git status --short`; preserve every unrelated change.
4. Rebuild both focused products before running their witnesses.
5. Review and land the exact isolated change set if `.git` is writable.
6. Extend shallow drill-forward only if dogfood identifies another clear modal
   churn problem; do not add modes, tabs, a preview pane, or permanent
   inspector chrome.
7. Do not manage or relaunch any Array app while Dylan's current live-app
   constraint remains in force.
