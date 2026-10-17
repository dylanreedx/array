# Reference notes

Frames extracted with `node_modules/.cache/film-bin/ffmpeg` at 10% / 45% / 80%
of each source's duration. Source videos kept at `refs/raw/` (gitignored).

## Reference 1 — @twoclipping UI morph loop

Source: https://x.com/twoclipping/status/2103273003555402193 (the "opus 5.5 is
f*cking cracked at motion design" post, not the course article link). 14.06s,
1440x1440, via fxtwitter's media API. Stills: `refs/twoclipping-1.png` (1.4s,
black pill/button, colour-icon corner), `refs/twoclipping-2.png` (6.3s, a
rounded toggle/switch mid-drag), `refs/twoclipping-3.png` (11.2s, a ⌘K-style
search card filtering "frame").

- Pacing: the tweet's own spec is 120 BPM / 7 bars with "something happens on
  every beat" — a beat is 0.5s. In practice the shape never cuts; it is
  continuously morphing, so there is no "change" to count, only a constant
  rate of transformation. The nearest thing to a discrete beat is a full
  state swap (button to loader to toggle to palette, etc.), which lands
  roughly every 1.5-2s — about one full UI concept per bar.
- Type size vs frame height: almost none. The only legible text is inside the
  command-palette state (frame 3): the input text ("frame") sits at roughly
  40px cap height in a 1440px-tall frame, about 2.8%. The result rows below
  it run about 32px, about 2.2%. There is no caption layer at all — the UI's
  own type is the only text on screen.
- Text and UI share the frame: they don't share it, they ARE the same object.
  There is no caption band; the "narration" is entirely in what the shape
  becomes and what the cursor does to it. No overlay, no side-by-side — one
  centred shape on an empty canvas.
- Palette: warm light-gray canvas (roughly #efede8), the morphing shape is
  pure black or near-black, with one small saturated accent (an orange/
  magenta/blue gradient icon-square) as the only colour hit. No gradients on
  the UI chrome itself.
- Take: camera-as-narrator (the "camera" is really a static frame with the
  subject moving/scaling inside it, but it reads as if something is always
  being revealed), cursor-led state changes (every transformation is a click,
  drag, or type — never an unmotivated cut), the restraint of one visual idea
  per beat, and the discipline of never repeating a composition.
- Leave: the single-shape-never-cuts structure itself (we have multiple real
  tiles, a zone, and a pull-back — that's a different grammar), the light
  warm-gray palette (ours is dark), and the near-total absence of caption
  text (our film is caption-led per the brief).

## Reference 2 — Linear in-product feature/support reel

Source: `https://webassets.linear.app/files/ornj730p/production/7eea0fd4bd8d2f019cb4f846cdb4b57ac444e1a4.mp4`,
found embedded in `linear.app/customers` and `linear.app/now`. 28.63s,
1920x1080 h264. Picked over Linear's /plan and /mobile hero assets because
those are either an abstract dark hero loop with no readable UI or a
hands-holding-an-iPhone lifestyle shot — this one is the closest thing Linear
publishes to a screen-capture feature reel (dark theme, Slack + Linear UI,
full-frame interstitial title cards). None of the candidates found hit the
45-90s range named in the brief; this is the best "any UI video" fallback.
Stills: `refs/linear-1.png` (2.9s, a Slack thread panel with a Linear bot
reply), `refs/linear-2.png` (12.9s, a full-black interstitial card reading
"Linear drafts a customer response"), `refs/linear-3.png` (22.9s, the same
thread panel resolved, with a Linear auto-reply to the customer).

- Pacing: much slower than the morph loop. Each beat is a whole scene — a
  Slack panel scrolls and fills in over several seconds, then a 2-3s black
  title card states what's about to happen in plain language, then the next
  UI scene plays out. Call it one real change (not a micro-interaction, a
  whole scene) every 4-6s across the 28.6s runtime — roughly 5-6 beats total.
- Type size vs frame height: the interstitial title cards are the biggest
  text in the piece — "Linear drafts a customer response" sits at about
  50px cap height in a 1080px frame, about 4.6%. In-UI text (the Slack
  thread, the Linear issue links) runs small, 16-24px, about 1.5-2.2% of
  frame height — deliberately subordinate to the chrome around it.
- Text and UI share the frame: they never share a frame. A title card is its
  own full-black shot with zero UI visible; the UI shots have no caption
  overlay at all. It's strict alternation, not a band.
- Palette: near-black background (#0a0a0a-#111), off-white/light-gray body
  text, a blue/violet accent for links and the Linear bot avatar, colourful
  user avatars as the only saturated hits. Close to our own dark-UI palette.
- Take: scale discipline (one panel, one thread, nothing crammed), restraint
  (no motion graphics flourish, the UI itself does the work), and the
  alternation pattern of "UI scene, then a plain-language card naming what
  just happened" — useful for a beat that needs to name a capability in
  words.
- Leave: the pace (4-6s per beat is too slow for a 24s/120 BPM film), the
  strict never-overlap of text and UI (our captions must sit in a reserved
  band *while* UI keeps moving, per the brief), and the reliance on a second
  full-black shot to carry every caption (we don't have the runtime to spend
  a whole beat on black).

## Rules I'd adopt

1. Caption cap height stays 7-8% of frame height for normal beats (matches
   the brief's 84px/1080p), up to ~11% (120px) only for the hook and the
   lockup line — never bigger than Linear's biggest title card (4.6%) by
   more than ~2.5x, so it reads as emphasis, not a billboard.
2. Cap one state-change per beat (0.5s at 120 BPM) on cursor/UI micro-moves,
   but one real "scene" change per bar (2.0s) minimum — faster than Linear's
   4-6s scene holds, slower than twoclipping's continuous morph, because we
   have real content (tiles, a zone) to read, not an empty canvas.
3. Every caption lives in the reserved bottom-18%-of-frame band and never
   overlaps a UI move, but unlike Linear's full-black interstitials, UI
   keeps running behind/above the band at all times — we cannot afford a
   beat with no product on screen.
4. One UI subject fills the frame per shot (one tile, one pane, one palette)
   at any beat that isn't an explicit pull-back — no two tiles compete for
   attention in the same beat.
5. Every state change is cursor-motivated (click, drag, keystroke, or a
   tool-row status flip) — never an unmotivated cut — and the last frame of
   the silent website cut should resolve to a state that reads as "done,"
   the way both references end on a settled, legible shape rather than
   mid-motion.
