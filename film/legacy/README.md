# legacy/: what the earlier films run on

Frozen. The earlier films (videos/board-story, power-tour, full-day, hero-loop, what-is-array, canvas-tour)
import from here: the old `lib/` (lens, replay of the website's demo, pointer tracks, caption bands), the old
`acts/` (the pink cursor, bubble, pills, caption band, lockup) and `previews/day` (full-day's transitions).
They were moved here unchanged from `.worktrees/hero-loop/film`, apart from import paths.

New videos never import from legacy/. They use kit/, which was refactored out of this code and the
which-tab film, and which takes every colour, face and timing from a look. If a piece here is worth reusing,
port it to kit/ and make it look-neutral first.

- Rendered from film/: board-story, power-tour, full-day (registered in videos/index.ts).
- Source only: hero-loop, what-is-array, canvas-tour. They replay the website's demo components through
  three seams (DemoStage, the AgentGyro phase prop, the CommandCenter portal container) that exist only in
  the `.worktrees/hero-loop` bench and never landed on integration. `lib/WebsiteStage.tsx` and `lib/gyro.ts`
  fail to typecheck here for that reason, and nothing registered imports them.
- `scripts/`: the old pipeline's helpers, kept for those films (track.py, day-footage.sh, day-render.sh,
  export-cues.ts, gate.ts, check-loop.ts, check-drift.ts, refs.sh). Their paths assume the old layout
  except day-footage.sh and day-render.sh, which were updated.
