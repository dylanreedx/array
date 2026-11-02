# 0.7.39 release (build 90): prep

2 November 2026. Bench `.worktrees/release-0739`, branch `array/release-0739`.
Prep only: nothing pushed, published, notarized or deployed. No appcast, no
production relay change, no full matrix yet.

## The merge

**The base is `origin/array/integration` (`b0689628`, 0.7.38, build 89), not
the local `array/integration`.**

The local `array/integration` in the main checkout is at `982d241e`. It is
stale. It forked at `61de0eb6`, before 0.7.32, and never received
0.7.32 to 0.7.38. Its 8 "newer" commits (iOS simulators on the canvas, tile
multiselect, group agent drag, CLI fixtures, palette test, ten app themes,
iOS preview agents, one phone alert per task) all shipped in **0.7.35**
(`0c28fc06`), cherry-picked under new hashes:

| Local integration | Shipped as | Patch |
|---|---|---|
| `efcce530` iOS simulators on the canvas | `221ab950` | same apart from run-matrix.sh context lines |
| `18b0f3da` multi-tile selection | `ff6acad9` | identical |
| `0e5e2ec9` group agent drag | `321a4ba3` | identical |
| `a7950c0d` CLI fixtures | `627fabe3` | identical |
| `55d88f95` palette test | `e95db500` | identical |
| `c4013d70` ten app themes | `02918b1a` | same apart from one inventory count line |
| `524e3104` iOS preview agents | `cbacd9c5` | identical |
| `982d241e` one phone alert per task | `413e56e0` | same; the one differing guard was already in the tree |

Merging `982d241e` would have replayed 8 shipped commits against 436 commits
of divergence, and gained nothing. So the bench was cut from
`origin/array/integration`. `array/preview-0739` is built on `b0689628`, so it
**fast-forwarded**: no merge commit and no conflicts. The run-matrix.sh,
inventory, ContinuumApp.swift, UIProbeAppearance.swift and sidebar/tile files
are exactly as the preview left them.

Tip: `adbeaa00`. That is 84 commits on top of 0.7.38, including the
preview's 15 merges (portal and every shared tile kind, live terminals and
terminal Stop, tmux stall fix, relay housekeeping, characters, sidebar sort
and filter, lead glyph and chip fix, the 0.7.38 live-tile refusal). There are
two more since the PREVIEW.md proof tip `92558673`:

- `98a1c3d7 feat(collaboration): let a multiplayer preview run the person's
  own CLIs` (MultiplayerPreview.swift, a ContinuumApp.swift arm,
  scripts/preview-0739.sh)
- `adbeaa00 docs(release): launch the preview on the real CLIs`

The local `array/integration` should be reset to the release tip once this
ships, or it will keep looking like it holds unreleased work.

## What built

| Build | Result |
|---|---|
| `scripts/prepare-ghosttykit.sh` | exit 0 |
| Debug, whole package (`swift build --disable-sandbox --skip-update`, under the lock) | exit 0, 181 s |
| Release configuration (`swift build -c release --product Array`, under the lock) | exit 0, no errors, 956 s |
| iOS (`xcodebuild … -sdk iphonesimulator`, as run-matrix.sh runs it) | BUILD SUCCEEDED |

The first debug and iOS attempts failed with "No space left on device": the
disk had 1.6 GB free. The `.build` caches of the shipped release benches
(release-0732, -0735, -0736, -0737) were removed: nothing had them open,
they are build caches only, and the benches and their commits are untouched.
That freed about 45 GB. At the end of prep there was 44 GB free. The full
matrix needs room too, so check `df -h` first.

## Legs on the merged tree

All on `adbeaa00`, run the way the matrix runs them: temp project and app
support, tmux off for app checks, `ARRAY_AGENT_ID` unset, `</dev/null`.

| Leg | Result |
|---|---|
| Journey `--relay local --mode b --name ReleasePortal` | 70 PASS, 0 FAIL; cleanup left nothing on the relay |
| Journey `--relay local --mode terminal --name ReleaseTerminal` | 32 PASS, 0 FAIL; cleanup left nothing on the relay |
| `--sidebar-sort-check` | pass |
| `--character-sprite-check` | pass (100 sprites x 10 s, 0 layouts, 0 draws) |
| `--tile-character-check` | pass |
| `--tile-multiselect-check` (multi-tile selection) | pass |
| `--agent-tile-reference-check` (group agent drag) | pass |
| `--companion-task-host-check` (one alert per task) | pass |
| `--ios-preview-tile-check` (iOS simulators) | pass |
| `ContinuumRevivedAgentUIChecks` (includes the ten app themes) | pass |

## Fixes folded in (2 November, second round)

Each was the newest tip of its branch, with its bench clean:

| Merge | Branch tip | What |
|---|---|---|
| `529ce623` | `array/sidebar-sort` `6e7cf64f` | the sort button sits in the search field's trailing slot, so search and scope keep their widths |
| `273ca13c` | `array/terminal-sharing` `1b80f909` | the shared terminal's palette is read through `GhosttyThemeSnapshot.color(hex:)` |
| `44bbb156` | `array/mp-share-kinds` `32368469` | the shared-tile check's stand-in page is drawn from tokens |

`array/preview-0739` was still at `adbeaa00`, already in the branch.

**One conflict**, in `SharedTileAppearance.swift`'s stand-in page. Both
colour fixes rewrote its header band: terminal-sharing used a system grey,
share-kinds drew the whole page from light-theme tokens. Kept share-kinds'
version: it covers the band and the rest of the page. `check-color-hygiene.sh`
passes with 0 new violations.

The "no agent responses" fix has not arrived; nothing for it is in the branch.

### After the fixes (tip `44bbb156`)

| Check | Result |
|---|---|
| `scripts/check-color-hygiene.sh` | passed: 27 allowlisted, 0 new |
| Debug, whole package | exit 0 |
| Release configuration, `Array` | exit 0, no errors, 878 s |
| iOS | BUILD SUCCEEDED |
| `--sidebar-screenshot-check` | passed, 48 images (4 widths x 2 appearances) |
| `--sidebar-sort-check` | passed |
| `--shared-tile-render-check` | passed |
| `--shared-terminal-render-check` | passed |

### Full matrix (`44bbb156`)

Run 09:47-10:37 from the agent shell: `ARRAY_AGENT_ID` unset, `</dev/null`,
`TERM=xterm-256color`, `caffeinate -u -i`, `CONTINUUM_SKIP_UI_BASELINES=1`
(Dylan was using the Mac, so no fixture window took the screen). 39 GB free
after.

**444 legs. 10 KNOWN-RED as expected, none unexpectedly passing. 3 failed,
none reproducible alone:**

- **`scripts/check-film-scenes.sh`**: 5 of 12 scenes. Four are the same as
  every release since 0.7.36 (`full-day`, `full-day-v2`, `v2-smoke`,
  `v2-smoke-day`). The fifth, `v2-day-check`, failed in the matrix: the
  scene's pointer found no bulk bar, so "bulk settle" never happened. Alone
  (`ARRAY_FILM_SCENE`, isolated like the script), it passed 2 of 2 on this
  build, and 2 of 2 on the preview's film binary. That reads as load in the
  matrix, not the sidebar change. Still worth a look: this scene also flaked
  during 0.7.37's A/B.
- **`--share-agent-relay-check`**: one step timed out ("the open popover
  sees Sam join"). Alone it passed 2 of 2 (34 steps). It passed in 0.7.38's
  and the preview's matrices.
- **`--character-perf-check`**: with characters on, panning showed 80 bar
  layouts and draws, against 0 with them off. Alone: release build 5 of 6
  (the one failure had a different signature: 77 card layouts on, 55 off);
  preview build 4 of 4. The only `TileNSView` change since the preview is a
  hit-test, which cannot lay anything out. The check allows zero stray
  layouts, so one unrelated event in an arm fails it. **To its owner: flaky,
  maybe not a regression, but it failed twice in 8 tries on this build.**

Found in passing, not new: CoreChecks' **dependencies guard fails** ("Core
target must include exactly AgentContent, AgentUI, GRDB…"). Core has also
depended on `ContinuumRevivedCollaborationProtocol` and
`…CollaborationClient` since at least 0.7.38 (`b0689628` has the same target).
The whole CoreChecks leg is KNOWN-RED for its seed-byte baseline, so this
second failure inside it is invisible to the matrix. Either the guard's
expected declaration needs the two collaboration targets, or Core shouldn't
depend on them.

### Journeys

The relay code is identical to what staging v12 runs (`07122561`): no line
differs in any relay target, `RelayPackage.swift`, the Dockerfile or the deploy
config. So staging was **not redeployed**, and needed no snapshot. Staging
health was 200 with schema 5, still v12.

| Journey | Local relay | Staging v12 |
|---|---|---|
| Portal, `--mode b` | 70 / 70 | 70 / 70 |
| Live terminal, `--mode terminal` | 32 / 32 | 31 / 32, then 32 / 32 twice |
| One agent + every kind, `--mode a` | 94 / 94 | 98 / 98 (with `--old-guest ReleaseJourney`, the real 0.7.38 guest) |

The staging terminal miss: "the guest's screen is the host's pane, line for
line". The guest held the host's lines, but with six blank rows where the
first lines should be, and the second printf wrapped differently. That was one
look at a screen over the real internet, mid-redraw. Every other terminal step
in that run passed (latency median 62 ms, 400 of 400 lines in order, the
flood within 1 s). The next two runs passed 32 / 32. Every run's cleanup left
nothing on the relay.

## Remaining gate steps

1. **Fold in the "no agent responses" fix** when it lands, then rebuild and
   rerun the legs above. The matrix needs a rerun only if that fix touches
   more than the agent path.
2. **Characters motion harness**, `scripts/canvas-motion/character-arms.sh`.
   It takes the screen for a few minutes, so run it with the Mac left alone.
   On and off should match.
3. **Linux relay gate**, `scripts/check-relay-linux.sh`.
4. **Production relay deploy, with Dylan's go.** Snapshot `relay_data`
   first. The rollback target is recorded in
   `.plans/105-collaboration/RELAY-DEPLOY.md`. Staging v12 already runs this
   relay code.
5. **RELEASE.md**, build 90:
   - Check `xcrun notarytool history --keychain-profile array-notary` first.
   - `scripts/release-app.sh … --set-version 0.7.39 --set-build 90`, then
     `scripts/check-app-bundle.sh --configuration release --channel prod`.
   - Both DMGs.
   - The appcast: run it with the main checkout's `releases/` path. It drops
     0.2.0, so re-insert it.
   - The ledger row.
   - The push: brace `${T}` in zsh refspecs.
