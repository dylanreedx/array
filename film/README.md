# film/: Array's film studio

Array's videos are made here: launch films, promos, lessons, changelog clips. Two halves:

1. The recorder films the REAL app. A film-only build of Array plays a scripted scene on a fixed 60 fps
   clock and saves every frame (`scripts/film-capture.sh`, scenes in `film/scenes/`). That is a take.
2. The edit (this folder) is Remotion: React compositions that cut, frame and dress the takes, render
   to video, and add type and sound.

Read PROCESS.md before starting a round, and TASTE.md before any creative call.

## Three choices per video, never defaults

Each video picks one of each. They mix freely, and none of them is a template.

- Purpose (`purposes/`): why it exists. Educational, initial launch promo, general promo, feature launch,
  changelog, social clip. A purpose is a list of brief questions (audience, length, hook, call to action)
  and says nothing about the look.
- Format (`formats/`): the story shape and its beats. Each built film left one behind (pull-back reveal,
  guided tour, day in the life, board story, power tour, seamless loop), and research/20's unbuilt ideas
  are there marked UNBUILT.
- Look (`looks/`): palette, type, motion grammar, sound.

A new video gets a NEW format and a NEW look unless Dylan asks to reuse one. The saved ones are
references to learn from. What every video does share is the kit.

## Layout

```
film/
  README.md  PROCESS.md  TASTE.md
  purposes/         one brief per purpose: questions only
  formats/          beat structures from finished films, and unbuilt ideas
  looks/<look>/     README.md (tokens, type, motion, sound) and, once ported, look.ts
  kit/              the shared building blocks, all look-neutral (below)
  videos/<name>/    brief.md, the composition (index.tsx, timeline.ts, ...), notes.md, tracks/
  scenes/           the recorder's scene builders (owned by the recorder side)
  probes/           measurements: jitter, blank faces, plate parity, still hold, lockup, compare
  scripts/          new-video, import-take, render, studio
  legacy/           the old lib and acts the earlier films run on (frozen; legacy/README.md)
  refs/             reference frames and notes from other people's films
  public/           fonts (OFL), marks (SVG, see marks/README.md); footage/ is linked in by import-take (gitignored)
  renders/          every render round (gitignored)
```

## How a take becomes a film

```
scene (film/scenes/)  ->  scripts/film-capture.sh  ->  ~/array-scratch/film/takes/<video>/<take>/
                                                         frames/000000.png ...  frames.json  <take>.mov
scripts/import-take <video> <take dir> --as <name>  ->  public/footage/<video>/<name>/   (hard links)
                                                         videos/<video>/tracks/<name>.json (rects, marks)
videos/<video>/  reads the track (where each tile is on every frame) and plays the frames with kit/footage
scripts/render <video> ...  ->  renders/<video>/r<N>/   preview.mp4  stills/  contact-sheet.png  notes.md
```

`frames.json` is the bridge. The recorder writes where every tile, zone and card sits on every frame, in
points, plus marks (named frames like `pullStart` or `bell`). The edit never guesses a position. A flying
card lands exactly on its real tile because it reads that tile's rect at that frame. Swapping footage is
one `import-take` command; code never names a run.

## Commands

Run them from `film/`. Setup once: `pnpm install && pnpm browser` (Remotion's pinned Chrome), and `uv`
on the PATH (Python helpers pin their own packages).

```sh
scripts/new-video first-agent --purpose educational             # fresh: brief, empty composition, notes
scripts/import-take which-tab ~/array-scratch/film/takes/which-tab/pullback --as pullback
scripts/render which-tab --stills 0,2.3,6.9,f444,s4             # just those frames, in seconds
scripts/render which-tab --proxy                                # 960x540, every other frame, with sound
scripts/render which-tab --range 6-9                            # one beat only
scripts/render which-tab                                        # 1080p review cut, with sound
scripts/render which-tab --4k                                   # the master
scripts/render which-tab --sequence --range 8.8-11              # lossless PNG frames, for the probes
scripts/studio                                                  # live scrub at http://localhost:3480
```

`--round 5.3` writes into an existing or chosen round, and otherwise each render starts the next round.
`--blur` adds real motion blur by accumulation, which is slow and for masters only. `--silent` drops
the sound. `--format square|portrait` renders other shapes, if the video lists them.

Times on this Mac, which-tab (16.5 s, 991 frames), with a warm webpack cache:

| Render | Wall clock |
| --- | --- |
| 6 stills (`--stills`), sheet included | 2.8-4.0 s (10.4 s cold) |
| proxy, 960x540 at 30 fps, with sound | 10.6 s |
| 1080p review cut, with sound | 21-32 s |
| 4K master | 37-49 s |

So iterate on stills and proxies, show Dylan the review cut, and render 4K last.

## Outputs

Everything has the same shape, and no name ever carries a date or time. Dates go inside files.

- Takes: `~/array-scratch/film/takes/<video>/<take>/`, named for what they are (`pullback`, `plate`).
- Rounds: `renders/<video>/r<N>/` holds `preview.mp4`, `stills/`, `contact-sheet.png` (every half second,
  or the stills), `notes.md` (the round's notes, PROCESS.md), `cues.json`, `soundtrack.wav` and `render.log`
  (the command and the time of each step).
- A delivery to Dylan copies the round folder to the program's `.plans/` folder, so it outlives the bench.

## The kit

Every piece takes its colours, faces and timings from a look (`kit/look.ts`) or from the caller. Nothing
in kit/ hard-codes ink, lime or a font.

| Piece | File | What it does |
| --- | --- | --- |
| Footage | `kit/footage.tsx` | Plays a take frame for frame; a footage lens frames a rect of it; `trackRect` reads a tile's rect |
| Plate-to-live hand-off | `kit/handoff.tsx` | A face cut from real pixels that can never be blank: plate first, live once the pixels agree |
| Motion blur | `kit/blur.tsx` | Directional blur from velocity (one pass), and accumulation sub-frames for masters |
| Claude, Codex, Pi | `kit/tui/` | Each CLI drawn in its real grammar on a terminal grid; sessions are data |
| Type, word-in | `kit/type.tsx` | Words rising through a mask, one after another; headlines that lift away |
| Lockup | `kit/lockup.tsx` | The end card in beats: line, then mark and wordmark, then URL, proportioned in H |
| Determinism | `kit/determinism.ts`, `kit/base.css` | No wall-clock motion; the page every film draws on |
| Formats | `kit/formats.ts` | Output shapes; 4K and proxy are scales of the same layout |
| Soundtrack | `kit/soundtrack.py` | Score and sound design synthesised from the cue sheet, plus Array's own sounds |
| Fonts, sheet | `kit/fonts.ts`, `kit/sheet.ts`, `kit/clock.ts`, `kit/anim.ts`, `kit/ContactSheet.tsx` | Loading faces, the cue sheet, the musical clock, easing |

## Rules that keep it working

- A frame is a pure function of its frame number: no `Math.random()` (use `rand(seed)`), no CSS transitions.
- Remotion uses ports 3480 (Studio), 3481 and 3482 (renders). Port 3000 is the recorder's browser tile.
- Never use Claude artifacts for film work, even for sketches. Prototype here, with stills and proxies.
- The recorder's real captures need Dylan's session unlocked and awake. When it's locked, WebKit tiles
  come out blank and the take still passes.
