# full-day: notes

Reference film (see legacy/README.md). It renders from film/ on legacy/.

## State

- r0 (2026-10-05): "This is amazing. I am beyond amazed right now." The notes that led to v2 are in TASTE.md.
- v2 r1 delivered 2026-10-05: `.plans/68-launch-film/full-day-v2-r1/` (3:46).
- Takes: six takes of one recorder run (01-morning, 02-late, 04-afternoon, 05-busy, 06-ship, 07-evening).
  The tracks have 3204 frames for 01-morning, which matches the full-day-v2 runs of 2026-10-05/06 in
  `~/array-scratch/film/`; the last is `full-day-v2-20261006T012516Z`. Rebuild footage and tracks with
  `legacy/scripts/day-footage.sh <run dir>`. Always recapture a WHOLE run: a partial recapture blanked the browser.
- tracks/ holds 6.6 MB of per-frame pointer data (about 0.4 MB compressed in git); day-footage.sh regenerates it.
- Sound: the transitions' sound design is a stem: `legacy/scripts/day-render.sh` writes
  `videos/full-day/stems/transitions.wav` and then runs scripts/render, which mixes the stem in.
