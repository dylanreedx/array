# 73 · Film studio: make the film harness permanent

Written 2026-10-16, after which-tab r5.3 ("it's gorgeous").

## Goal

The film harness and the Remotion edit become one permanent `film/` in the
repo, with consistent outputs. It must make any kind of video Dylan wants,
not just more of the ones we've already made. Every new video starts fresh
unless he says otherwise. The iteration process that worked on which-tab is
written down so any session can run it.

## Decisions (Dylan, 2026-10-16)

1. The `--film` recorder is compiled into a film-only build. The shipped app
   never contains it.
2. The earlier films (board-story, power-tour, full-day, what-is-array,
   hero-loop, canvas-tour, which-tab) come along as references.
3. The app bugs that filming found land on integration first, as ordinary
   fixes with their own witnesses, before the recorder moves.
4. Never use Claude artifacts for film work, not even for sketches. The
   harness is the only place videos get made. Instead, build a fast proto
   mode into the harness so early iterations are quick.

## Three choices per video, not templates

Each video picks one of each. They mix freely, and none is a default.

- **Purpose:** why it exists. Educational, first launch, general promo,
  feature launch, changelog, quick social clip. The purpose sets the brief
  questions: audience, length, hook, call to action. It says nothing about
  the look.
- **Format:** the story shape. Pull-back reveal, split screen, recipes,
  exploded view, uncut take, tour. It sets the beats and the timing.
- **Look:** palette, type, motion grammar, sound.

New videos get a new format and a new look by default. Saved ones are
references to borrow from. Reuse happens only when Dylan asks for it.

What is shared is the kit of building blocks. Each one was expensive to build
once, and each one is free to reuse:
- real footage and the plate take
- the shared-element hand-off and morph
- motion blur
- the Claude, Codex and Pi TUIs
- the logo lockup
- the measurement probes

## Layout

```
film/
  README.md        how it works, one page
  PROCESS.md       the iteration loop
  TASTE.md         Dylan's likes and rejections, in his words, with dates
  purposes/        one brief template per purpose
  formats/         beat structures, taken from finished films
  looks/           saved looks: tokens, type, motion, sound
  kit/             shared Remotion building blocks
  scenes/          capture scene builders
  probes/          jitter, blank-face, plate parity, still-hold, pixel compare
  videos/<name>/   brief.md, scene builder, edit, notes.md
  scripts/         new-video, capture, import, render, proto
```

Swift: `Sources/ContinuumRevived/App/Film/` behind a compile-time flag. Only
`scripts/film-capture.sh` builds with it. The film bundle id stays
`dev.arrayapp.macos.film`.

Outputs, the same shape every time and never dated in a name:

```
~/array-scratch/film/takes/<video>/<take>/   raw takes (frames, frames.json, .mov)
film/renders/<video>/r<N>/                   gitignored
  preview.mp4  stills/  contact-sheet.png  notes.md
```

Each round's `notes.md` holds:
- Dylan's notes, verbatim and numbered
- what changed
- the cause of each fix, in plain words
- the measurements
- the weak spots still open, and a self-score

## Fast iteration (proto mode)

A full round today means a 1-minute capture at 2x and 60 fps, then a full
4K render. Ideas to measure in phase 3:

- **Proto capture:** 1x scale, 30 fps, JPEG frames, no ProRes, and only the
  frame range being worked on.
- **Stills first:** render only the frames at changed beats, in seconds,
  before any full render.
- **Proxy edit:** render at 960x540 with half the frames for blocking, and at
  4K only for the review cut.
- **Live scrub:** Remotion Studio on port 3480 with the take loaded, so
  Dylan can scrub a beat in the browser while an agent edits.

Phase 3 measures today's times first, then each idea, and keeps what
actually saves time.

## Phases

1. **Land the app fixes.** Separate the bug fixes in the film-harness bench
   from the harness itself. Land each one on a bench branch off
   `origin/array/integration`, with a RED→GREEN witness, including
   `footage/pin-failed-output.patch`. Run the matrix, then stop for Dylan
   before merging into integration.
2. **Move the recorder.** Forward-port the harness onto integration behind
   the film-only compile flag. Run `--film-scene-check` on every scene. The
   recorder must be absent from a normal build, and a check must prove it.
3. **Move the edit and set the conventions.** Move the Remotion factory to
   `film/`. Split `kit/` from the videos. Bring in all earlier films as
   references. Set up the output layout and the no-dates take names. Write
   README, PROCESS, TASTE, and the purposes, formats and looks taken from
   the finished films. Build and measure proto mode.
4. **Prove it.** Re-render which-tab r5.3 from the new `film/` and compare it
   to the bench render with a frame diff. Then start one new video from
   `scripts/new-video` to show that the fresh-by-default path works.
   **Status:** 20 commits on `array/film-fixes` (bench `.worktrees/film-fixes`):
   18 fixes and features, 1 test, 1 matrix chore. Inventory in
   `phase1-fixes.md`. Matrix: 281 legs, 270 passed, 10 KNOWN-RED, 1 real failure.
   The failure is `capture-cli-fixtures.sh check`: there is no capture for
   claude 2.1.302, and it fails on a clean integration build too. Waiting on
   Dylan: which of the six feat commits land, and whether to merge.
   **Phase 3 status:** 4 commits on `array/film-studio` (2667a690..dc93e60f).
   - which-tab r5.3 re-renders with 0 pixel and 0 audio difference.
   - Render timings: 4K 37–49 s, proxy 10.6 s, 6 stills 3–4 s.
   - Open:
     - hero-loop, what-is-array and canvas-tour are kept as source only. They
       need website code that only exists in the hero-loop bench.
     - the pink-persona and caption-band looks are not yet ported to code.
     - footage is hard-linked from the old dated take folders. Re-import it
       from `takes/` once phase 2 lands.
   **Phase 2 status (2026-10-17): merged locally.** Integration is at 5ec9fce4.
   - The 8 recorder commits are 00ce24c2..5ec9fce4.
   - All 12 scenes pass `--film-scene-check`.
   - `check-film-absent.sh` passes.
   - The full-day v1/v2 reference scenes now allow wider close-ups:
     closeUpMinZoom 0.40 and 0.35, because today's two-row layout can't reach
     0.85.
   - The Settings clicks were dropped from v2-day-check and full-day-v2,
     because the SwiftUI Settings form has no targets the recorder can point at.
   - Not done, to save usage:
     - the slim matrix leg (it still runs all 12 scenes, about 12.6 min)
     - importing proto takes into the edit
     - a full matrix run after the last two commits (the run before them:
       305 legs, and the only real failure besides the scene leg was
       capture-cli-fixtures)
   - App finding: a sidebar row that is rebuilt mid-click swallows the click.
     A user could hit this too.
   **Next video:** the dictation film, handed off in `.plans/76-dictation-film`.
5. **Return the benches.** Remove `.worktrees/film-harness` and
   `.worktrees/hero-loop` only after everything in them has landed or been
   moved.
