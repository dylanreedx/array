# 76 · Dictation film: handoff

Written 2026-10-17 by the session that built `film/` (plan 73). The next agent
starts here. Dylan is switching models for the weekend, so this file has to
be enough on its own.

State at handoff:
- Local `array/integration` is at `5ec9fce4`, plus this handoff's commit;
  nothing is pushed.
- It holds the whole studio: `film/`, and the recorder, which is compiled only
  into the film build by `scripts/film-capture.sh`.
- All 12 film scenes pass `--film-scene-check`.
- `scripts/check-film-absent.sh` passes.

## The idea, in Dylan's words

"We just added dictation, and I think the UI is pretty solid. I want to have
that as the main focus... a short promo video... a dictation prompt.
Obviously you don't hear it. Maybe there's some nice upbeat music loud
enough, with captions. But the main idea is that you can prompt between all
your providers. Unify and in a consistent manner. We also added colors,
color coordination to agents, so maybe we can highlight that. So I'm
thinking just you start with prompting, the audio wave visualizer is moving,
and then it's spanning across the canvas while dictating the other agents,
but it's the same prompt... It's just flowing through them, different type
of cuts between them. Maybe there's a few jump cuts, maybe there's split
cuts, maybe like split screen. But I want to showcase that you're doing
Claude and Codex. And now we should also mock up Gemini, as well as Meta,
maybe. Just some extra logos in there. We're not going to add their CLI
support just yet, but just for the video's sake."

So the video is:
- one spoken prompt
- the waveform moving
- the same words flowing through agents of different providers, each one in
  its own colour
- cut together with jump cuts, split cuts and split screen
- upbeat music and on-screen captions, because nobody hears the voice

## Read first, in order

1. `CLAUDE.md`: the repo rules. They apply to every agent and every model.
2. `film/README.md`: how the studio works, its commands and outputs.
3. `film/PROCESS.md`: the iteration loop Dylan likes. Follow it exactly.
4. `film/TASTE.md`: what Dylan has loved and rejected, in his words.
5. `film/formats/split-screen.md` and `film/formats/pull-back-reveal.md`:
   references only. This video gets its own new format and look.
6. `film/purposes/feature-launch.md` and `film/purposes/social-clip.md`.
7. `.plans/73-film-studio/README.md`: what is built and what is still open.

## Blockers to clear before filming

1. **Dictation is not on `array/integration` yet.**
   - It lives in bench `.worktrees/dictation-composer` (branch
     `array/dictation-composer`): one commit, 39bb119e, plus a large
     uncommitted change. The uncommitted change adds:
     - `ComposerDictationController`
     - `ComposerDictationPillView`
     - `ComposerDictationStripView`
     - `ComposerDictationButton`
     - `Packaging/Array.entitlements`
   - Another session owns that bench. Never edit, commit or stash in it.
   - Check whether it has landed:
     `git log array/integration --oneline -i --grep=dictation`.
     If it hasn't, ask Dylan before going further.
2. **Agent colours are not on integration yet.**
   - They live uncommitted in bench `.worktrees/agent-colour` (branch
     `array/agent-colour`), with witness `AgentIdentityColorChecks.swift`.
   - Same rule: wait for it to land, and don't touch the bench.
3. **The film harness can't drive dictation yet.**
   - A capture has no microphone, and must never use the real one.
   - Add film-only director steps behind `#if ARRAY_FILM`. They feed the real
     dictation controller a scripted level sequence (for the waveform) and
     scripted partial and final transcript text, so the real UI states
     render: idle, listening, partial, final, inserted.
   - Never mock the dictation UI in Remotion; real footage is the rule.
   - Prove it with `--film-scene-check` on the new scene, and keep
     `scripts/check-film-absent.sh` green (the shipped app must carry none of
     this).
4. **Does "the same prompt flowing through agents" exist in the app?**
   - Find out whether Array can send one prompt to several agents at once.
   - If it can, film that.
   - If it can't, film the same prompt dictated into each agent in turn, and
     let the cuts carry the "flow". Never caption a broadcast feature that
     doesn't exist.
   - Tell Dylan which one it is in round 1's notes.

## Gemini and Meta (Dylan's decision, with one open point)

- Dylan wants Gemini and Meta in the video as extra provider logos, even
  though Array has no CLI support for them yet.
- Dylan supplied the marks. They're saved as
  `film/public/marks/provider-gemini.svg` and `provider-meta.svg`, beside
  the real provider marks. `film/public/marks/README.md` lists every mark and
  says where each one may appear.
- Keep them out of the app, its scenes and `website/public`; use them only in
  the Remotion edit.
- Open point to raise in round 1: whether a public cut needs a "coming soon"
  style label. Array's copy rule is to claim nothing it can't do, and the
  marks belong to Google and Meta. Ask; don't decide.

## Suggested shape (a starting point, not a template)

- Purpose: feature-launch, cut down as a social clip.
- Length about 15–25 s; 16:9 master, with 1:1 and 9:16 from the same edit.
- Format: new. Working name "relay": one prompt handed from tile to tile.
- Look: new. Not ink-lime (which-tab's look) and no pink. The agent colours
  are the palette's hero, so build the look around them.
- Sound: upbeat track plus captions in the picture; `film/kit/soundtrack.py`
  is the starting point.

## Commands

- `film/scripts/new-video dictation --purpose feature-launch --title "..."`
  (name it something short; no dates in any name)
- `scripts/film-capture.sh film/scenes/<video>/<scene>.json --proto`, then
  `--frames A-B` while blocking a beat, then a full capture for the review cut
- `film/scripts/import-take`, `film/scripts/render` (`--stills` and `--proxy`
  first, 4K only for review)
- `film/probes/`: run jitter, blank-faces and still-hold before showing Dylan
  anything

## Rules that cost real time to learn

Git:
- Commit only as Dylan, with no Co-Authored-By or AI trailer.
- Subjects use `type(area): description`.
- Never push. Merges are local and need Dylan's OK.
- Never `git stash`; the stash is shared by every worktree.

Where to work:
- Work in your own bench, `.worktrees/<slug>` made with `git worktree add`.
  Never use the main checkout; it holds other sessions' uncommitted edits.
- Never touch `/Applications/Array.app` or `~/Documents/personal`.

Capture:
- The screen must be unlocked; a locked screen films blank editors.
- The film window must never take Dylan's display.
- Remotion uses ports 3480–3482; port 3000 is the harness browser tile.

Checks:
- Never guess a `--*-check` flag; list the real ones from
  `ContinuumApp.swift`.
- Never pipe `swift build` into `tail`; it hides a failed build.
- tmux only with a private `TMUX_TMPDIR`, never the default socket.
- Run the matrix with `CONTINUUM_SKIP_UI_BASELINES=1`, and never set
  `CONTINUUM_UPDATE_BASELINES`.

Film work:
- Never use Claude artifacts or HTML mockups for film work; only the harness
  and the Remotion edit.
- Report to Dylan in plain words: what you found, why it happened, then
  details. Number his notes verbatim in each round's `notes.md`.

## Leftovers from plan 73 (not this video's job, but don't redo them)

- Slim the matrix's film-scene leg (about 13 min down to about 5).
- Let `import-take` and the kit footage loader accept proto takes. Final
  renders must still refuse them.
- Re-import which-tab's footage from `~/array-scratch/film/takes/` (the
  studio still hard-links the old dated folders).
- Return the benches `.worktrees/film-harness`, `.worktrees/hero-loop`,
  `.worktrees/film-recorder` and `.worktrees/film-studio` once their work has
  landed.
- The claude 2.1.302 CLI fixture needs Dylan's OK to record.
