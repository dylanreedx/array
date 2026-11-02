# Agent characters: ready for the 0.7.39 gate

Written 2026-11-01. Branch `agent/agent-characters-build-ducks-679c0f0c`, rebased on
0.7.38 (`b0689628`), local and unpushed. Feature work is done. The release gate (one
full matrix over everything going into 0.7.39) and one clean motion-harness rerun are
still owed; both belong to the gate, not this branch.

## What it adds, in plain words

- Agent characters: a small animated pixel duck beside each agent, in the sidebar
  row and in the tile header, acting out what the agent is doing (typing, reading,
  searching, running, thinking, waiting for you, finished, failed, asleep).
- Off by default. Settings › Appearance › Agent characters has the switch, a Motion
  choice, the set picker with Import…, a live-reloading themes folder and a preview
  grid. Reduce Motion shows a still pose.
- Each agent gets a character from a hash of its id; the tile's ⋯ menu (or an agent,
  through `agent.update` with `character`) can pick a different one.
- Agents can make new sets: a JSON file in the themes folder, checked with
  `--validate-agent-character-theme`, documented in
  `docs/internals/agent-characters-authoring.md`.
- The eight built-in ducks are MIT-licensed pixel art; the notice is in
  `LICENSES/AgentCharacters-Ducks-MIT.txt`, `THIRD_PARTY.md` and next to the assets.

## Commits (b0689628..f6736995, plus this note)

37c8d7b7 docs(agent-characters): research Duckherd characters and plan sprites
0483a707 feat(agent-characters): parse character theme files and bundle ducks
1ed5d611 feat(agent-characters): resolve each agent's pose from its turn
8bb6c573 feat(agent-characters): draw characters with one shared animated layer
8a567edc feat(agent-characters): show each agent's character in the sidebar row
68f3ebf4 feat(agent-characters): show the character in the agent tile header
7d6a782d feat(agent-characters): import and preview character sets in Settings
7030e2b8 test(agent-characters): measure characters on and off at 80 tiles
7056734e fix(agent-characters): place characters in the two-line sidebar cards
89361fbd feat(agent-characters): let each agent have a chosen character
b6a27a33 feat(agent-characters): reload sets agents make in the themes folder
b5796b61 test(agent-characters): witness the row and the tile showing one pose
247f3639 feat(agent-characters): add a preview app cycling agents through states
4217ffa6 test(agent-characters): add characters on and off motion harness arms
63114a93 fix(agent-characters): use the shared default name and pin the resource
076348c6 docs(agent-characters): record round two's build and matrix state
f128b4e2 docs(agent-characters): point the plan at the reworded default-name fix
77faf747 test(agent-characters): count prose re-measures by cause in the harness
096ed267 fix(agent-characters): label the re-measure trigger's backing scale
f6736995 docs(agent-characters): record the on-screen motion harness numbers

## Motion harness: characters cost nothing measurable

Release "Array Motion" bundle built from this branch, 80 tiles, unlocked display.
Off and on interleaved, three rounds each, same background load (load average 4.4-6.0
from other benches compiling):

| | off | on |
|---|---|---|
| zoom, camera states/s | 28, 28, 28 | 28, 28, 26 |
| zoom, main thread per commit (median) | 26.38 ms | 26.19 ms |
| zoom, instructions per commit (median) | 362 M | 357 M |
| pan, camera states/s | 57, 55, 54 | 56, 56, 57 |
| pan, main thread per commit (median) | 8.33 ms | 8.23 ms |

## Counter evidence: characters never cause a transcript re-measure

A first, non-interleaved pair of zoom arms showed 3-5 extra full prose re-measures
with characters on. To find out why, the harness report now counts re-measures by
cause (`77faf747`): width-triggered re-measures, row re-measures, and the last width
triggers with their backing scale.

Every arm afterwards, from `~/array-scratch/motion-runs/*/report.json`:

| arms | width re-measures | row measures | width triggers |
|---|---|---|---|
| ab-off-zoom-1..3, ab-off-pan-1..3 | 0 | 582 | none |
| ab-on-zoom-1..3, ab-on-pan-1..3 | 0 | 582 | none |
| dx-off-1..2 | 0 | 582 | none |
| dx-on-1..2 (characters animating) | 0 | 582 | none |
| dx-frozen-1..2 (characters on, `CANVAS_MOTION_CHARACTER_MOTION=never`) | 0 | 582 | none |

The 582 row measures are the first layout of the same transcripts, identical in every
arm. No arm, on, off or frozen, had a single width re-measure. So the earlier extra
re-measures were timing in that one run, not characters: a character sits in its own
fixed slot and never changes a transcript's width.

## Owed at gate time

1. One clean motion-harness rerun on an idle, unlocked Mac:
   `scripts/canvas-motion/character-arms.sh`, characters off versus on. Expect the
   numbers above and zero width re-measures.
2. The full matrix, run once by the gate over everything in 0.7.39. This branch's
   own rerun was stopped on purpose at leg 94 (it held the shared build lock). Up to
   there the only failures were `scripts/check-film-scenes.sh` and
   `--browser-automation-engine-check`, both red the same way in 0.7.38's own matrix.
   The branch's legs to look for in the summary: `--agent-character-theme-check`,
   `--agent-character-pose-check`, `--character-sprite-check`,
   `--sidebar-character-check`, `--tile-character-check`,
   `--character-settings-check`, `--character-themes-live-check`,
   `--character-perf-check`, `--workspace-api-agent-character-check`.

Nothing pushed, notarized or released.
