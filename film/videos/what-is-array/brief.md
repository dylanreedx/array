# Director's brief · "What Array is"

Video 1 of the social series. 24 seconds, 120 BPM, 60 fps master, 12 bars.
Posted solo on X, LinkedIn and the README; also the hero clip on arrayapp.dev
in a silent cut. It must teach a stranger what Array is without any text
around it.

Written 2026-10-04 after the hero-loop review. The hero loop proved the
pipeline and the component fidelity; it did not carry context, narration, a
hook or a payoff rhythm. This brief fixes the film, not the harness.

## Film in one line

An agent needs you, and on Array's canvas you can see which one, because
every agent, and everything it touches, is a tile in view.

## Goal and audience

Developers who run coding agents in terminals and tabs and have never heard
of Array. After 24 seconds they should be able to say: it's a Mac app, agents
and their tools live as tiles on one canvas, you launch anything with ⌘K, and
colour tells you who needs you. Nothing else.

## References (two frames, pick or veto)

1. The UI morph loop by @twoclipping (907K views, in the 0xMovez course):
   one subject never cut, a cursor drives every state change, the camera is
   the narrator, last frame equals first. Take: camera-as-narrator, cursor-led
   changes, type rhythm. Leave: the single-shape morph, the gradient palette.
2. Linear's 45 to 90 second feature reels: UI at readable scale, one subject
   per shot, restrained type, no voiceover. Take: scale discipline and
   restraint. Leave: the light theme and the pace, ours is faster.

Before building, extract three frames from each with ffmpeg, write
`refs/notes.md` describing pacing, type size relative to frame, and how
captions share the frame with UI. Do not start the timeline before that.

## Truth rules

- Only shipped behaviour (research/09-feature-truth.md). Real labels: the
  palette rows are "Agent" and "Terminal", the model step is "Choose Model",
  sections are Needs You, Recent, Create, Workspaces & Projects, Actions.
- Copy: direct, spatial, product-specific. No em dashes. No generic
  productivity language. Verbatim site copy where possible: "Keep every agent
  in view." and "Free during alpha" and "macOS 14+ · Apple silicon".
- It is the real UI rendered from the website's own components with a
  scripted scene. Label it internally "scripted scene". Never call it an
  unscripted session. No real credentials, paths or tokens on screen.
- Companion does not appear.

## Cast (the tiles)

Three agents in zone "Canvas fixes": Fix tile jump (Codex, working), Audit
tokens (Pi, working), Release notes (Claude Code, needs attention on a
`git push`). Beside them a Terminal, a Browser on localhost and a Diff Review
tile, so "what it touches" is literally next to the agent. A second zone,
"Release 0.7.24", sits to the right so the pull-back has somewhere to go.
Sessions are the unique 6 to 8 entry transcripts from `hero-loop/scene.json`,
allowed to grow during the film.

## Beat sheet

Bars at 120 BPM, four beats per bar, 2.0 s per bar. A payoff every 3 to 5 s,
the hook inside 2 s. Captions are the narration; one line per beat, never two
on screen at once, never over UI.

| Bar | Time | Camera and picture | Caption |
| --- | --- | --- | --- |
| 1 | 0:00 | Cold open, black. An amber "Needs attention" pill fills 60% of the frame width, pulsing at the attention rhythm. Two-note ping. | An agent needs you. |
| 2 | 0:02 | Spring pull-back (heavy) reveals the pill belongs to one of three agent tiles in a zone on the dark canvas. The amber ring draws on. | Which one? You can see. |
| 3 | 0:04 | Push in (default spring) to the amber tile. Its transcript scrolls one line; the tool row "git push -u origin HEAD" shows In progress. | Every agent runs in a tile. |
| 4 to 5 | 0:06 | Slide right along the zone: Terminal streaming `swift test`, Browser reloading localhost, Diff Review opening. Each lands on a beat. | What it touches sits next to it. |
| 6 | 0:10 | Pull back to show the zone header "Canvas fixes · 2 working · 1 needs you" and the second zone's edge. | Zones hold a project. |
| 7 to 8 | 0:12 | ⌘K chip. Command Center opens with the real sections. Type "agent", row "Agent", Choose Model (Quick Start, Anthropic, OpenAI Codex), Return. A fourth tile lands and its neighbours shift on the beat. | ⌘K launches anything. |
| 9 | 0:16 | Cursor hits "Allow once" on the amber tile. Amber to blue; ping resolves. | Amber needs you. |
| 10 | 0:18 | Pull back wide. Tiles turn green left to right on beats 1, 2, 3; ascending arpeggio to the tonic. | Green is done. |
| 11 | 0:20 | Canvas dims. Array mark springs in (heavy, no overshoot). | Keep every agent in view. |
| 12 | 0:22 | Lockup holds. | arrayapp.dev · Free during alpha · macOS 14+ |

Silent website cut: bars 2 to 10 without captions, then the frame settles on
the wide shot and holds. Plays once.

## Text on screen

- Caption face: Inter or Geist (open licence), weight 600, 84 px at 1080p,
  up to 120 px for the hook and the lockup line. SF Pro stays inside the UI.
- Band: bottom 18% of the frame in 16:9; a top band in 9:16 so the tile fills
  the middle; the composition reserves it and no UI move crosses it.
- Enter: 14-frame spring rise with opacity; exit: 8-frame fade. Word-level
  reveal only on the hook and the lockup.
- Key chips (⌘K, ↵) bottom right, 56 px, same face.

## Motion

- Closed-form springs only, from `lib/anim.ts`: snappy for chips and pills,
  default for camera and tiles, heavy for the mark and big type. Tiny
  overshoot on UI, none on type.
- A value with more than one target uses `track()` (one spring per change,
  each from its own start time) so any frame renders without simulating the
  frames before it.
- Tidy and tile landings keep the native 110 ms curve; the camera is the film's
  liberty and may glide.

## Sound

Synthesised on the cue sheet with `scripts/soundtrack.py`. Motif: blue
working is a low pad, amber attention a two-note ping (bar 1, resolving in
bar 9), green done a chime, the bar 10 wave an ascending arpeggio to the
tonic. 120 BPM, C major, mastered to -14 LUFS. The silent cut ships muted.

## Formats

16:9 1920x1080 and 3840x2160 masters, 9:16 1080x1920 and 1:1 1080x1080
reflowed through the lens (one tile at phone width, captions in the top
band), OG still at bar 2, poster at bar 10, srt from the cue sheet, README
GIF of bars 2 to 10.

## Workflow gates

1. Brief approved (this file).
2. References extracted and notes written.
3. Stills: render bars 1, 2, 4, 7, 9, 11 as stills. Score them.
4. Animatic: full timeline, captions as plain text, no sound.
5. Full pass: springs, cursor, sound.
6. Critique rounds (below) until every score is 8 or more.
7. Masters, reflows, stills, GIF, sync check, drift check, gate.

## Critique loop

Each round: render the contact sheet every half beat plus six stills; score
each still 1 to 10 on hook (would a stranger stop scrolling), readability at
phone size (view the 9:16 at 540 px wide), pacing (something changes every
3 to 5 s), truth (every label and claim is real), and craft (type, spacing,
motion mass). Write the three worst problems, fix them, re-render. Stop when
every score is 8 or better and the reviewer agrees. Record scores in
`critique.md` so the next video starts from what this one learned.

## Deliverables

`out/what-is-array/`: 1080p and 2160p masters with sound, 9:16 and 1:1
cuts, silent website cut (mp4 + webm + poster), OG still, GIF, srt, chapters,
contact sheet, stills, `critique.md`, and this brief alongside `timeline.ts`,
`scene.json`, `script.md`.

## Pipeline work this video needs

- Caption layer with reserved bands per format and a word-reveal mode.
- Lockup act: Array mark from `website/public/array-logo-light.svg`, wordmark,
  URL line.
- Hook act: a UI element framed alone at 60% width, then revealed in place.
- Springs and `track()` in `lib/anim.ts` if Tessel's lift did not bring them.
- A format-aware lens band so no camera move crosses the caption band.
- Scored critique template (`critique.md`) and a `--stills` list in render.sh
  per video.
- Reference extraction script (`scripts/refs.sh <url|file>`).
