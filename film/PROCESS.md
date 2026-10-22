# How a film gets made: the iteration loop

This is the loop that took "Which tab was that?" from r1 to r5.3 in one day, ending with "it's gorgeous".
Dylan named the process itself as the thing to keep: "i love our iteration process, i feel like you take
the feedback and suggestions really well". Follow it for every video.

## The loop, once

1. Brief. `scripts/new-video <name> --purpose <p>` writes brief.md from the purpose's questions. Answer
   them, show Dylan, and get a yes before building anything. Brainstorm first when he asks for that: "dont
   change yet just brainstorming" means report back and stop.
   Choose delivery shapes up front with `--outputs landscape|vertical|both`. For both, plan each beat's
   subject and framing in both shapes; for vertical alone, no landscape edit is required. See MOBILE.md.
2. Styleframes. A few stills that decide the look (type specimens, the key frames of each beat). Make them
   in the harness (`scripts/render --stills`), never as Claude artifacts. He picks or vetoes.
   Review every requested shape, including vertical at phone size and with the intended feed's overlays.
3. Takes. Write the scene for the recorder, capture, and import with `scripts/import-take`. Check a still of
   any WebKit tile (browser, editor) before trusting a take, because a locked screen blanks them while the
   take still passes.
4. Proto. Block the beats with `--stills` at the beats you are working on and `--proxy` for timing.
   `--range` renders one beat. `scripts/studio` lets Dylan scrub while you edit.
5. Round. `scripts/render <video>` makes the 1080p review cut with sound in `renders/<video>/r<N>/`. Fill
   in the round's notes.md (below). Open the folder in Finder for him ("no open finder with the video pls").
6. His notes come back. Go to "Taking notes".
7. Last. `scripts/render <video> --4k` for the master, plus any other formats, once he says it's done.
   `--format both` renders the two authored versions together; `--format vertical` renders only vertical.

## Taking notes

- Dylan's notes go into the round's notes.md verbatim and numbered, typos included, before any work starts.
  When the work is split across agents, each agent gets the numbered notes word for word, never a summary.
- Find the cause before fixing. A note is a symptom ("there is jitter with each tile"). Find what produces
  it, and measure it with a probe (probes/) before changing anything. His wording is a clue: "it looks
  shaky" pointed at sub-pixel snapping, "blank for a few moments" at faces cut from outside the capture.
- Every fix is backed by a number: a probe reading before and after (reversals on a held edge, the
  near-black share of a card face, the max diff across a hold, mark/H on the end card). If no probe measures
  the problem, write one, and add it to probes/ if it will be needed again.
- Fix the class, not the frame. One owner for a behaviour beats a patch per symptom.
- A decision made in chat must be visible in the render. Check the stills for it before delivering ("WE
  DIDN'T SWITCH THE FUKCING DRAGGING CURSOR", 2026-10-05).

## Keep rounds side by side

- Never overwrite a round. Each one is `renders/<video>/r<N>/`. A small follow-up is r5.1, r5.2.
- Each round has stills at the beats that changed (named for the beat and the frame,
  `handoff-7.4s-f444.png`) and a contact sheet, so a change can be judged without playing the video.
- Deliveries go to the program's `.plans/` folder next to the earlier rounds (`preview-opening-r4.mp4`,
  `preview-opening-r5.mp4`), so the previous round is one click away.

## What a round's report says

notes.md in the round folder, and the message to Dylan, cover the same things in plain words:

1. His notes, verbatim and numbered.
2. What changed, one line per note.
3. The cause of each fix, in plain words ("the faces were cut from the live take while its camera was
   still tight, so the tiles were outside the frame and came out black").
4. The measurements: each probe, before and after.
5. What is still weak, said plainly, before he finds it.
6. A self-score: hook, readability, pacing, truth, craft. The score is for honesty, not for approval. On
   2026-10-04 a film self-scored 8 or more everywhere and failed his first look, so his notes always win.

## Truth rules

- Real app only. Footage comes from the recorder, never from a mock or a zoomed screenshot. The website's
  demo components were rejected for film on 2026-10-04 ("our in-app components look marginally better than
  the copied ones").
- No invented states. A tile shows what the app really shows in that state: read it from the source, and
  never draw a custom ring where the app has marching ants. Real Claude Code agents never show Allow/Deny,
  so don't film an approval beat on them.
- Real model ids and names, exactly as each CLI reports them (claude's initialize handshake, codex
  model/list, pi --list-models), and real UI labels.
- When a film shows the same agents in two places (tabs and tiles), the names match exactly.
- Agents look deep into their work: long transcripts, no "Ready. Type a prompt" line.
- Shipped behaviour only, and no speed claims we can't back up. Claim visibility.
- When filming finds an app bug, fix it in the app with a witness (CLAUDE.md), not in the edit.

## Two specialists, one relay

For a film with real footage, run two specialist agents and keep the main session as the relay:

- Footage agent: scenes, the recorder, takes, frames.json, parity between takes, app bugs found by filming.
- Motion agent: the edit, meaning timing, the kit, type, sound and renders.

The main session holds the brief and Dylan's notes. It passes each agent the notes that concern it
verbatim, reviews what comes back, and reports to Dylan. The specialists don't talk to Dylan directly.
Fan out more agents for research (references, end cards): that is where they paid off (research/20,
research/22). Never Fable subagents.

## Proto first, 4K last

| Step | Command | About |
| --- | --- | --- |
| A beat's look | `scripts/render <v> --stills 6.9,7.4,f444` | 3-4 s |
| Timing of the whole film | `scripts/render <v> --proxy` | 10 s for 16 s of film |
| One beat in motion | `scripts/render <v> --range 6-9` | seconds |
| Scrub while editing | `scripts/studio` | live |
| Review cut for Dylan | `scripts/render <v>` | 20-30 s |
| Master | `scripts/render <v> --4k` | 40-50 s |

On the recorder side, a proto capture (lower scale, fewer frames, only the beat in work) is the
recorder's job (film/scenes). Ask for it rather than recapturing a whole run for one beat. But recapture
whole runs for anything that will ship: a partial recapture blanked the browser once.

## Never

- Never Claude artifacts for film or video, not even a sketch or a pilot (Dylan, 2026-10-16). The
  artifact pilots of 2026-10-15 "all look horrible... cheesy".
- Never a date in a file or folder name. Takes, rounds and videos are named for what they are.
- Never ship a frame that can be blank, jitter on a hold, or drift a real take. Probe it.
- Never default to an earlier video's format or look. Fresh unless Dylan says otherwise.
