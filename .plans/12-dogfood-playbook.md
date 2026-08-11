# Dogfooding Array while building it — the playbook

Written 2026-08-11, after shipping 0.4.3 → 0.4.8 in one day, mostly by finding
things while using the app. This is the loop that worked, the traps that wasted
hours, and the current state.

Companion docs: [`11-session-handoff-2026-08-11.md`](11-session-handoff-2026-08-11.md)
(what shipped, per-release), [`RELEASE.md`](../RELEASE.md) (the runbook),
[`docs/VERSIONING.md`](../docs/VERSIONING.md) (the ledger — next build number).

---

## 1. The two-install rule (never break this)

| Install | Channel | Root | Rule |
|---|---|---|---|
| `/Applications/Array.app` | prod | `~/Documents/personal` | **Your workspace.** Never rebuilt, never quit by an agent. Changes only when a release ships and you take the update. |
| `~/Desktop/Array Dev.app` | dev | `~/array-scratch` | **The preview window.** Rebuild/relaunch freely; nothing in it needs to survive. |

Split by **role**, never by project. Two installs on one project root share
`<root>/.array/` and the last writer wins — that really cost a canvas nine tiles
once (hazard 9 in `CLAUDE.md`).

```sh
scripts/dev-app.sh              # quit, rebuild, relaunch — ~5-25s
scripts/dev-app.sh --no-launch  # rebuild only
```

Debug, not release: release config is whole-module optimization (~6 min); debug
is incremental (~15s). Release config is for shipping only.

---

## 2. The loop: "I noticed something weird" → shipped

### Step 1 — Capture it, don't describe it

**Screenshot the thing.** Six times today a verbal description sent me to the
wrong surface; a screenshot resolved it in one look. Two of the day's worst bugs
(⌘K rendering as a sidebar, the model list "missing" codex) were *only* found
this way, after hours of green checks.

If it's visual, paste a screenshot. If it's behavioural, say what you did and
what you expected.

### Step 2 — Identify WHICH surface

Array has near-duplicate controls, and this is where time gets lost. Notably:

- **Two model pickers.** ⌘K's New Agent step is a flat list
  (`LaunchProfilePalette.availableAgentModels`). Settings ▸ Agents ▸ Default
  Model is a two-pane rail (`ProviderModelPicker.swift`). *Fixing one does not
  fix the other* — that mistake caused four rounds of "still only Anthropic".
- **Two "titles" on an agent tile.** The chrome header (`Agent · <model>`, from
  `tile.title`) and the agent's display name (from `AgentRecord.displayName`).
- **Two agent lists.** ⌘K's Agents & Tiles / Needs You / History rows, and
  (before 0.4.5) the sidebar's inbox.

So: name the surface, or screenshot it.

### Step 3 — Reproduce in the dev app, visually

```sh
scripts/dev-app.sh
screencapture -x -o /tmp/shot.png     # then look at the PNG
```

**Do NOT drive the GUI with `osascript` keystrokes.** Focus can move between
`open -a` and the keystroke — a stray prompt got typed into an unrelated tmux
Claude session that way today. If a keystroke is genuinely needed, do it by hand.

### Step 4 — Find the real code path, not a plausible one

Ask "what does production actually call?" The ⌘K-as-sidebar bug survived a full
day of green `--palette-duplicate-root-check` runs because that check builds its
own plain host view, while production's host was an `NSSplitView` that
overwrote the palette's frame. **The check never touched the thing that was
broken.**

Useful probes:

```sh
# What the app actually resolves for backend/models, per defaults domain
defaults read dev.arrayapp.macos "continuum.agents.backend"
defaults read dev.arrayapp.macos.dev "continuum.agents.model"

# Real flags — never guess one; an unknown flag falls through and boots the app
grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u

# Which app is actually running, and is it the binary on disk?
ps -eo pid,lstart,command | grep "Array.app/Contents/MacOS/Array"
lsof -p <pid> | awk '$4=="txt"'     # compare inode to the bundle's binary
```

### Step 5 — Fix, with a witness that has teeth

Every change carries a deterministic witness — a `--*-check` flag, a CoreChecks
section, or a bundle assertion — that is **RED before the fix and GREEN after**.
Prove both directions:

```sh
# 1. break production deliberately, confirm the check fails
# 2. restore, confirm it passes
swift build --product ContinuumRevivedCoreChecks   # ALWAYS rebuild before trusting
.build/debug/ContinuumRevivedCoreChecks --command-center-check
```

When you must retire a witness because behaviour intentionally changed, **invert
it, don't delete it**. Four of today's assertions now assert absence (the mount
must produce no sidebar; the toggle must not be palette-discoverable; the View
menu must not offer it; searching "workspace sidebar" must return nothing). The
sidebar cannot creep back silently.

### Step 6 — Gate it

```sh
scripts/run-matrix.sh
```

**Targeted checks are not enough**, twice proven today:

- They never compile Core for iOS. The iOS build was red from 0.4.3 to 0.4.5
  (`Process`, `homeDirectoryForCurrentUser` in shared Core).
- They don't run separate check *executables*. `ContinuumRevivedPaletteChecks`
  is its own product; `Array --palette-*-check` never invokes it.

Expect exactly **one** failure: ComponentLab at **36 baselines** (documented
KNOWN-RED). Any other number means you moved a baseline — find out which:

```sh
grep -oE "^  - [a-z0-9.-]+\.png" /tmp/matrix.log | sed 's/^  - //' | sort -u
```

If a baseline changed because your change was *intended*, review the diff PNG
(magenta = changed) and bless **only those files** by copying their `.actual.png`
over the committed baseline. **Never** run `CONTINUUM_UPDATE_BASELINES=1` — it
sweeps the 36 in with yours, laundering unreviewed drift.

### Step 7 — Ship

Follow [`RELEASE.md`](../RELEASE.md) exactly. Short form:

```sh
scripts/release-app.sh --identity "Developer ID Application: Dylan Reed (46TTB6J9DZ)" \
  --notary-profile array-notary --set-version X.Y.Z --set-build N
```

Then: verify version/build **from the mounted DMG**, copy to `releases/`, publish
BOTH assets (`Array.dmg` + `Array-X.Y.Z.dmg`), `scripts/generate-appcast.sh`,
append the ledger row, commit, push `array/integration`, fast-forward `main`,
spot-check the live feed.

Build number `N` is Sparkle's comparison field: **+1 every release, never
reused**. Next is in the ledger.

**Read the release script's OWN exit code.** A release failed silently today
during codesign of Sparkle's nested `Autoupdate`; the harness reported success
because the command ended with `| tail`. Put `echo "EXIT=$?"` last, or check the
DMG exists.

---

## 3. The four traps (all the same disease)

**A witness that does not drive production passes while production is broken.**

1. **The check builds its own host/fixture.** → ⌘K mis-hosted in an
   `NSSplitView` for a whole day of green checks.
2. **Two surfaces, one fixed.** → "only Anthropic models," reported four times.
3. **The gate isn't in the targeted set.** → iOS build red across three releases.
4. **Separate check executables.** → `ContinuumRevivedPaletteChecks` red,
   invisible to app flags.

Antidote: after fixing anything visible, *look at it in the running app*.

Bonus trap: **a stale check binary.** `swift build --product A --product B`
honours only the LAST `--product`. Rebuild the exact product before trusting it.

---

## 4. Current state (0.4.8, build 14)

Shipped today: ⌘K command-center redesign; semantic completions + fuzzy `@` file
navigation; codex context occupancy from the rollout log; camera-move chrome
redraw fix; codex transcript rehydration; **the workspace sidebar removed** with
every tile-less agent reachable from ⌘K first; managed agents inheriting the Home
you're working in; the iOS build repaired; ⌘K floating properly; provider headers
in **both** model surfaces; agent tiles named after the model they run.

`array/integration` = `main`, nothing unreleased.

### Open — needs your decision

1. **Duplicate codex rollout locators with conflicting policies.**
   `CodexRolloutTelemetry.rolloutURL` **abstains** when a thread matches in both
   `sessions/` and `archived_sessions/`; `CodexRolloutLocator` lets the **active
   tier win** (archiving transiently duplicates). Both witnessed. Collapsing them
   changes shipped behaviour and rewrites a pinned check.
2. **36 ComponentLab baselines.** Some are now genuine 0.4.3 composer/completion
   changes rather than old drift. Needs you reading diffs.

### Open — just work

3. **Context gravity** isn't wired into `ManagedAgentSpawnHomeResolver`'s
   precedence at the call site (rung passes nil, skipped not defaulted).
4. **`wip/pre-0.4.3`** holds composer pasteboard intake; mostly superseded.

---

## 5. Map — where to look first

| Symptom | Start here |
|---|---|
| ⌘K contents, categories, ordering | `Core/LaunchPaletteModel.swift` |
| ⌘K appearance, geometry, headers | `App/LaunchProfilePalette.swift` |
| Window layout / overlay hosting | `ContinuumApp.makeWorkspaceContentView` (returns a PLAIN container on purpose) |
| Settings model picker (two-pane) | `Canvas/AgentComposer/ProviderModelPicker.swift` |
| Agent tile chrome / title | `App/TileSpawner.swift` + `ContinuumApp.renameManagedAgentTileForModel` |
| Which agents appear where | `TilelessAgentPaletteRow`; membership from `InboxSort.section(for:now:)` — never re-derive |
| Model catalogue / providers | `Core/AgentModelCatalog.swift`, `AgentModelConfig.swift`, `AgentBackendConfig.swift` |
| Codex occupancy / rehydration | `Core/AgentProviders/CodexRolloutTelemetry.swift`, `CodexSessionTranscriptReader.swift` |
| Agent lifecycle, reopen | `App/AgentSupervisor.swift`; `revealAgentFromInbox` is the whole reopen path |

### Environment facts worth knowing

- **`pi` is a Node script**; `node` lives under nvm. A GUI-launched app has a thin
  PATH, so the catalogue probe only works because
  `PiAgentRunner.liveExtraDirs()` expands nvm version bins. A bare thin env fails
  with `env: node: No such file or directory`.
- **`cfprefsd` ignores `HOME`.** Only the channel split and explicit suite names
  isolate preferences.
- **Core is compiled into the iOS target.** Anything macOS-only in
  `ContinuumRevivedCore` needs `#if os(macOS)`.
