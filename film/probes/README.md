# probes/: measurements

Every fix in a round is backed by a number from one of these (PROCESS.md). They read numbered PNG frames
(a take's `frames/`, or `scripts/render <video> --sequence --range a-b`, which writes lossless frames to
`renders/<video>/r<N>/frames/`), and most also read a video. Each is a uv script: it installs its own
pinned packages on first run.

| Probe | Usage | Measures |
| --- | --- | --- |
| jitter | `probes/jitter.py <frames> <from> <to> --edge NAME=x,ROW,LO,HI --label NAME=X0,Y0,X1,Y1,LUM` | Sub-pixel position of borders and labels per frame: moves, largest move, reversals |
| blank faces | `probes/blank-faces.py <frames> <rects.json>` | Share of each moving card's face that is near-black (nothing on it) |
| plate parity | `probes/plate-parity.py <live take> <plate take> --from 140 --to 599 --step 3` | Per tile, the first take frame from which plate and live pixels agree (the hand-off table) |
| still hold | `probes/still-hold.py <frames> <from> <to> [--rect X,Y,W,H]` | Any pixel that changes across a hold that should be still |
| lockup | `probes/lockup.py <end-card still.png>` | Mark/H, gap/H ink to ink, mark centring on the caps, lockup centring, URL spacing |
| compare | `probes/compare.py <a.mp4> <b.mp4> [--audio]` | Max and mean pixel difference per frame between two renders (and their sound) |

A video supplies its own geometry where a probe needs it: `npx tsx videos/which-tab/rects.ts 396 527`
prints the card rects that blank-faces reads.

What each read on which-tab r5.3 (2026-10-16), as a baseline:

- jitter, wide hold (frames 528-660): zone, browser, Subscriptions and Order export borders 0 moves; the
  Plan picker edge probe jumped between two edges once (a probe-placement artefact, not motion).
- blank faces (frames 396-527): worst 0.037 (Cart total at f423, still showing its terminal), the rest
  0.000-0.008.
- still hold (frames 870-990, the end card): 0 frames changed.
- lockup (f960): H 75 px (6.94% of the frame), mark/H 1.400, gap/H 0.507, mark centred on the caps
  (+0.0 px), lockup x +0.0 px and y +1.5 px from centre, URL top 1.19H below the baseline.
- plate parity (takes, frames 140-599 every 3, tolerance 2.0): Plan picker 302 and Subscriptions 314 (the
  film's HANDOFF uses 301 and 312), Dark mode, Renewal emails and Order export 227 (the film uses 238, a
  margin after the pull-back lands at take frame 228). Cart total reads 263, but it never uses the plate:
  it is in the live frame from frame 0.
- compare against the delivered r5.3: 0 max difference over 991 frames, and identical sound.
