# Dogfooding Array while building it — the playbook

Written 2026-08-11 after shipping 0.4.3 → 0.4.8 in one day, mostly by finding
things while using the app. Updated 2026-08-12 through 0.4.13. This is the loop
that worked, the traps that wasted hours, and the current state.

The 2026-08-12 additions are worth reading even if you know the rest: the
verification gate was reporting **4 of its 135 app legs** and had been for long
enough to hide a bug that silently discarded every image pasted into a composer.
Traps 5 and 6 in §3, and step 6's rewrite, are that story.

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

When behaviour intentionally changes, change the witness rather than deleting
it. The sidebar checks now lock the corrected distinction: the persistent left
workspace sidebar must mount and remain toggleable, while the window content
view must remain a plain container so ⌘K can never be laid out as an accidental
right-edge split-view pane.

### Step 6 — Gate it

```sh
scripts/run-matrix.sh
```

**Targeted checks are not enough**, twice proven today:

- They never compile Core for iOS. The iOS build was red from 0.4.3 to 0.4.5
  (`Process`, `homeDirectoryForCurrentUser` in shared Core).
- They don't run separate check *executables*. `ContinuumRevivedPaletteChecks`
  is its own product; `Array --palette-*-check` never invokes it.

**Read the summary the matrix prints at the end, not the exit code alone.** Since
`865b0d3` it runs every leg and closes with a report:

```
---- Matrix: 148 leg(s) run ----
KNOWN-RED, expected (7): …
Matrix passed.
```

Before that commit the script was bare calls under `set -euo pipefail`, so the
FIRST documented KNOWN-RED aborted it — a real run reached **4 of 135 app legs**.
Everything after was dead code, which is how `--composer-image-components-check`
sat in the file failing from the day it was written. If you add a leg, it is
reachable now; the allowlist of expected reds is `MATRIX_KNOWN_RED` in that
script, and a leg on that list which *passes* is reported too, because a stale
allowlist silently re-hides whatever it still covers. **Builds still halt** on
purpose.

Two traps when editing `run-matrix.sh`:

- **Two program checks pin its text verbatim.** `check-agent-tile-ux-program.sh`
  and `check-sidebar-native-ux-program.sh` both `grep -Fxc` for
  `run scripts/check-…-program.sh` and require exactly one match; the first also
  locks the matrix's first four lines byte for byte. Those two lines must stay on
  `run`. The agent-tile check is the matrix's OWN preflight (line 4), so breaking
  it kills the run in two lines of output.
- **The inventory records legs by literal invocation.** Renaming a wrapper reads
  as deleted checks. Bless by hand; `CONTINUUM_UPDATE_MATRIX_INVENTORY=1`
  regenerates everything and launders unrelated drift. Its extractor's leg
  pattern must also learn any new wrapper name.

**Do not trust a baseline count you have not just measured.** The "exactly 36"
figure in earlier docs is stale: as of 2026-08-12 it is **44** for
`--component-lab-check` and **45** for `--ui-baseline-check`, identical across
three worktrees with different subsets of that day's commits, so the drift
predates them and is still unexplained. To see which images:

```sh
grep -oE "[a-zA-Z0-9.]+-[0-9]+x[0-9]+-(aqua|darkAqua)\.png" /tmp/matrix.log | sort -u
```

Use that regex, not `grep '^  - '` — the failing list lives inside a single-line
NSError description, so an anchored pattern silently captures a fraction of it
(it gave me 9 of 36 once and I nearly diffed two partial sets).

A surface with **no committed baseline** is invisible to the count in both
directions: the agent-inbox surface changed height 320x660 → 320x652 with the
count unmoved. And "identical at HEAD" does **not** prove a shift is
environmental — a worktree shares its base's history, so that comparison cannot
separate inherited from environmental.

If a baseline changed because your change was *intended*, review the diff PNG
(magenta = changed) and bless **only those files** by copying their `.actual.png`
over the committed baseline. **Never** run `CONTINUUM_UPDATE_BASELINES=1` — it
sweeps every unreviewed one in with yours.

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

**Read the command's OWN exit code, and put `echo "EXIT=$?"` on its own line
immediately after — never after a `tail`/`grep`.** A pipeline's status is the LAST
stage's. This has now produced three false "success" readings: a release that
failed during codesign of Sparkle's nested `Autoupdate`, and twice a `git merge`
that had actually **aborted** while `MERGE_EXIT=0` came from `tail`. The failure
text was in the output both times; only the status code lied.

**`no identity found` from codesign is the SANDBOX, not a missing certificate.**
A release that dies with
`Developer ID Application: Dylan Reed (46TTB6J9DZ): no identity found` has not
lost its Developer ID — an agent's sandboxed shell cannot reach the login
Keychain. Verify before re-issuing anything:

```sh
security find-identity -p codesigning -v | grep "Developer ID Application"
```

If that prints the identity, the cert is fine and the release needs an
unsandboxed shell (agents: `dangerouslyDisableSandbox: true`; humans: your own
terminal). The same sandbox also blocks AppKit's pasteboard service, which made
`--composer-image-components-check` die on an unrelated early assertion and hid a
real bug for a whole release — if a check fails suspiciously early on a service
it should have, re-run it unsandboxed before believing the failure.

**Build numbers are cheap; batching is not free.** 0.4.11, 0.4.12 and 0.4.13
shipped within hours of each other, each carrying one verified fix. Shipping the
freeze fix alone got Dylan working again ~40 minutes sooner than waiting to batch
it with the features would have.

---

## 3. The four traps (all the same disease)

**A witness that does not drive production passes while production is broken.**

1. **The check builds its own host/fixture.** → ⌘K mis-hosted in an
   `NSSplitView` for a whole day of green checks.
2. **Two surfaces, one fixed.** → "only Anthropic models," reported four times.
3. **The gate isn't in the targeted set.** → iOS build red across three releases.
4. **Separate check executables.** → `ContinuumRevivedPaletteChecks` red,
   invisible to app flags.
5. **The witness is outside the gate.** → `--composer-image-components-check` sat
   in `run-matrix.sh` failing from the day it was written, because the matrix
   halted ~140 lines earlier. Every image pasted into a composer was silently
   discarded for two releases. Fixed in `865b0d3`; when you add a check, confirm a
   real `scripts/run-matrix.sh` run actually *reports* it.
6. **The assertion greps source instead of watching behaviour.** →
   `--managed-agent-model-spawn-check` asserted the app source *contained the
   string* `AgentModelConfig.resolved(selection: model)`. A reviewer replaced the
   refusal with `?? resolvedFromDefaults()` — the exact inverse of the fix — and
   the check still printed `passed`. Assert the outcome (no tile, no record, a
   message naming the model), not the call site.

Antidote: after fixing anything visible, *look at it in the running app*.

Bonus trap: **a stale check binary.** `swift build --product A --product B`
honours only the LAST `--product`. Rebuild the exact product before trusting it.

Bonus trap: **a red leg that hides its own siblings.** `--agent-supervisor-check`
stops inside itself at the KNOWN-RED naming section, so later sections in the same
leg never run. The `865b0d3` gate fix cannot help there — it makes legs after a
red leg run, not assertions after a red assertion.

---

## 4. Current state (0.4.13, build 19 — 2026-08-12)

`array/integration` = `main` = `a931b75`, nothing unreleased.

Shipped 2026-08-11: ⌘K command-center redesign; semantic completions + fuzzy `@`
file navigation; codex context occupancy from the rollout log; camera-move chrome
redraw fix; codex transcript rehydration; every tile-less agent reachable from ⌘K;
managed agents inheriting the Home you're working in; the iOS build repaired; ⌘K
floating instead of rendering as a right-edge pane; provider headers in **both**
model surfaces; agent tiles named after the model they run; the persistent left
workspace sidebar restored.

Shipped 2026-08-12:

| Version | Build | What |
|---|---|---|
| 0.4.11 | 17 | **The freeze.** Codex rollout lookup read an ~18 KB `session_meta` line ONE BYTE PER SYSCALL across every file in `~/.codex/sessions` — 688 files, 15.5M syscalls per agent restore, measured at 97% CPU for 90 s with the main thread blocked (five `cpu_resource` reports in one day). |
| 0.4.12 | 18 | **Every image pasted or dropped into a composer was silently discarded.** The composer handed Core's platform-neutral validator a UTType (`public.png`) where it demanded a MIME type (`image/png`); the throw landed in the `catch` that counts failures. |
| 0.4.13 | 19 | ⌘K resolves the model once and refuses a departed one out loud; inbox reveal titles from the agent's own record; zone jumps stop stranding the keyboard in an off-screen tile; a reveal stops zooming out from closer than 1.25×; the matrix reports 148 legs instead of dying at 4. |

### Open — needs your decision

1. **⌘K default row selection ranks on text alone.** `nav z` selects
   "Create Zone…" instead of a zone named Alpha, because `rankPrecedes` scores
   "Create **Z**one…" above a title that only matches via its `"zone"` alias.
   This single defect is TWO of the seven KNOWN-RED legs
   (`--nav-mode-check`, `--palette-first-responder-restore-check`), so fixing it
   retires them instead of accumulating more. Decision: should navigation rows
   outrank creation rows whenever the query matches a target's name, or only
   inside nav mode?
2. **The baseline count is 44/45, not 36, and nobody knows why.** See step 6.
   Needs review, not blessing.
3. **`scripts/check-root-docs.sh`'s marker list** is the pre-`65d420a` taxonomy
   and demands "Continuum Revived" in the user-facing README — which contradicts
   the identity rule. Which markers still matter is a docs call.
4. **Duplicate codex rollout locators with conflicting policies.**
   `CodexRolloutTelemetry.rolloutURL` **abstains** when a thread matches in both
   `sessions/` and `archived_sessions/`; `CodexRolloutLocator` lets the **active
   tier win** (archiving transiently duplicates). Both witnessed. Collapsing them
   changes shipped behaviour and rewrites a pinned check.
5. **The palette closes regardless of whether a dispatch succeeded.** A refused
   ⌘K model now beeps and names the model, but keeping the palette open on failure
   would change every dispatch branch.

### Open — just work

6. **`--agent-supervisor-check`'s naming flake** is the one KNOWN-RED that hides
   sibling assertions *inside* its own leg, so the gate fix does not reach it.
7. **`count ContinuumRevivedCoreChecks 74 → 76`** inventory drift, from the ⌘K
   redesign. Three agents have declined to launder it; it wants blessing in a
   commit that owns those two suites.
8. **Context gravity** isn't wired into `ManagedAgentSpawnHomeResolver`'s
   precedence at the call site (rung passes nil, skipped not defaulted).
9. Red but **outside the gate**: `--terminal-default-readability-check`,
   `--previous-focus-navigation-check`, `--zone-framing-readability-check`.

---

## 5. Map — where to look first

| Symptom | Start here |
|---|---|
| ⌘K contents, categories, ordering | `Core/LaunchPaletteModel.swift` |
| ⌘K appearance, geometry, headers | `App/LaunchProfilePalette.swift` |
| Window layout / overlay hosting | `ContinuumApp.makeWorkspaceContentView` (returns a PLAIN container on purpose) |
| Settings model picker (two-pane) | `Canvas/AgentComposer/ProviderModelPicker.swift` |
| Agent tile chrome / title | `TileSpawner.spawnManagedAgentForSelectedModel` / `…ForExistingAgent` — ONE seam; `renameManagedAgentTileForModel` was deleted in 0.4.13, nothing repairs a title after creation |
| Which agents appear where | `TilelessAgentPaletteRow`; membership from `InboxSort.section(for:now:)` — never re-derive |
| Model catalogue / providers | `Core/AgentModelCatalog.swift`, `AgentModelConfig.swift`, `AgentBackendConfig.swift` |
| Codex occupancy / rehydration | `Core/AgentProviders/CodexRolloutTelemetry.swift`, `CodexSessionTranscriptReader.swift`, `CodexRolloutLocator.swift` |
| Agent lifecycle, reopen | `App/AgentSupervisor.swift`; `revealAgentFromInbox` is the whole reopen path |
| Camera framing / tile reveal | `Core/CameraFraming.swift` (`revealWorkViewport`, AppKit-free) + `ContinuumApp.revealTileForWork` — one helper for every reveal |
| Zone jumps / input scope | `ContinuumApp.completeZoneJump` — all five zone routes; `fitNavZone` opts OUT of landing on canvas because nav mode only gets keys while it owns `activeSurface` |
| Composer image paste / drop | `Canvas/AgentComposer/ComposerImagePasteboardDecoder.swift` (speaks UTType) → `managedContentType` translates to MIME at the Core seam → `AgentComposerAttachmentStore` (speaks `image/*`) |
| The verification gate itself | `scripts/run-matrix.sh` — `MATRIX_KNOWN_RED`, `run_leg`, `matrix_classify`, `matrix_report` |

### Environment facts worth knowing

- **`pi` is a Node script**; `node` lives under nvm. A GUI-launched app has a thin
  PATH, so the catalogue probe only works because
  `PiAgentRunner.liveExtraDirs()` expands nvm version bins. A bare thin env fails
  with `env: node: No such file or directory`.
- **`cfprefsd` ignores `HOME`.** Only the channel split and explicit suite names
  isolate preferences. A check that writes `UserDefaults.standard` therefore
  writes the REAL domain — and `check-app-bundle.sh --channel prod` runs palette
  checks inside the bundle, so such a check can rewrite the user's configured
  agent model. Inject a private suite instead. A per-run suite leaves an empty
  42-byte plist in `~/Library/Preferences` that cfprefsd recreates after the
  process exits; that was measured, and it cannot be cleaned from inside.
- **Core is compiled into the iOS target.** Anything macOS-only in
  `ContinuumRevivedCore` needs `#if os(macOS)`.
- **The agent sandbox blocks the Keychain and AppKit's pasteboard service.**
  `codesign` fails with `no identity found`, and pasteboard-dependent checks die
  on early unrelated assertions. Neither means the certificate or the code is
  broken — re-run unsandboxed and confirm with
  `security find-identity -p codesigning -v`.
- **A screenshot and a browser image-copy are NOT the same pasteboard.** A Chrome
  "copy image" pastes into the composer; a screenshot may not. Probe with a
  throwaway Swift script over `NSPasteboard.general` — `item.types` plus
  `item.data(forType:)` per type, where `nil` data means the flavour is promised
  lazily rather than absent — before theorising about which one is at fault.
