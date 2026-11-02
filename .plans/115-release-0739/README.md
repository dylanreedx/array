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

## Still to come before the gate

Fixes the orchestrator will send to fold in:

- the possible "no agent responses" bug;
- the cramped sidebar search header (fails the sidebar screenshot check);
- two colour-hygiene reds (shared terminal palette, the fake web page in a
  shared-tile check).

Fold each in with a merge (`chore(release): merge … into the 0.7.39 release
branch`). Rebuild debug and release, then rerun the legs above.

## Remaining gate steps

1. **Full matrix** on the final tip, display unlocked and awake. Unset
   `ARRAY_AGENT_ID`, use `</dev/null`, `TERM=xterm-256color` and `caffeinate -u`.
   The baseline: 12 KNOWN-RED; the 3 display legs fail on a locked screen; the
   film scenes check has failed since 0.7.36. Anything else is real.
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
