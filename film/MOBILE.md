# Array films for a vertical feed

A person watching on a phone should understand Array's Mac workspace. The subject is the desktop
product; the delivery canvas is 9:16. Choose `--outputs vertical` for an independent film or `both`
for two versions of one story. A film can share its look, footage, sound and beats while composing
each shot differently. The companion app does not need to appear to justify a vertical film.

## The brand in this frame

The promise is still “Keep every agent in view.” Use the real app, recognizable session identities,
its actual activity indicators, and the existing Array mark and wordmark. Keep the mark's trail and
clear space intact ([brand guide](../brand/BRAND.md)). Type can be larger for the feed while keeping
the product's system voice. Palette, pacing and music remain creative decisions for each film;
vertical delivery does not impose one saved look on every video.

Make the workspace understandable in stages. Open on one recognizable problem, show one readable
action that resolves it, then reveal enough of the canvas to connect that action to the wider
workspace. “Everything in view” can be communicated through consecutive close views with identity
continuity and a short spatial reveal. A tiny entire desktop held for several seconds cannot carry
that explanation on a phone.

An illustrative story, not a required template:

| Beat | Landscape framing | Vertical framing |
| --- | --- | --- |
| Hunt for a session | Several windows establish the problem | One readable recap, then a deliberate cut to the next |
| Recognize it in Array | Sidebar beside canvas | Sidebar close-up: retain source, session name and status |
| Continue work | Row and open agent in one shot | Follow the same identity from row to transcript/composer |
| Understand the workspace | Wider canvas and related browser | Short contextual reveal, then a readable result close-up |
| Remember Array | Quiet end card | Recompose the existing mark, wordmark and URL inside the portrait frame |

Do not imply the Mac app has a narrow mobile layout. Preserve the captured interface; the editorial
camera can move through it. Separate cuts can show surfaces that cannot be read side by side in 9:16.
Avoid cropping away the control, pointer target or status that proves a claim. Captions sit near the
current action, so the viewer can read both without scanning the whole height.

## Authoring the shots

`new-video --outputs both` writes a landscape composition in `index.tsx` and a separate empty
`portrait.tsx`, registered through `versions.portrait.Component`. `--outputs vertical` uses the
portrait component as the film's only composition. Neither scaffold is an automatic conversion.

Share `timeline.ts` when timing works in both shapes. If the vertical story needs different holds,
captions or cuts, set `versions.portrait.build` to its own timeline builder. The renderer uses that
builder for duration, cues, score and contact sheets as well as picture. A different crop does not
require redoing a good score; a different edit requires checking the score against its own cues.

Use `FootageKey` rects in take pixels, based on `trackRect`, with deliberate subjects per beat.
`cropAround(take, subject, box)` in `kit/framing.ts` fits a crop around that subject at the output
aspect and bounds it to captured pixels. For example:

```tsx
const keys = [{ at: 0, rect: (box: Rect) => cropAround(take, chosenSubject, box) }];
<Footage take={take} from={0} keys={keys} banded={false} fit="cover" background={LOOK.color.ground} />
```

`chosenSubject` must be a visible rect in take pixels; use a new key as the shot's focus changes.
Overlays tied to footage use the same `footageView` / `toOutput` transform. Recompose type and the
end card for width, including line breaks and mark size, rather than scaling everything by height.

When the subject itself is too wide, a crop cannot preserve everything. Change the shot, show the
interaction in consecutive inserts, or capture a new take with a better native camera position.
Keep within the footage kit's pixel-magnification guidance. A new aspect does not create more detail.
Full-frame footage or an intentional designed background should occupy the canvas; padding a complete
landscape export into portrait leaves the action too small.

`mobileSafeArea` is a conservative editorial starting point for essential captions, logo and actions:
6% left, 12% right, 10% top and 20% bottom. Background imagery continues to the edges. These margins
are not an official specification for any platform. Inspect the intended destination's current
preview/overlays before delivery and adjust the composition to them.

## Review and delivery

Start with `scripts/render <video> --format both --stills <beats>` or just `--format vertical`.
Then render a proxy in each requested shape. Check the portrait version at roughly phone display
size, including sound off: one clear subject, readable key text, uncropped controls, captions near
the action, and a recognizable Array finish. Review contextual wide shots for meaning rather than
trying to make all their text legible.

Landscape files retain `renders/<video>/r<N>/preview.mp4`; portrait files live at
`renders/<video>/r<N>/portrait/preview.mp4`, with separate stills, contact sheet, cues, soundtrack
and notes. Both formats share a round number and log. Vertical-only creates only the portrait version.
Masters remain the last step after each composition is approved.
