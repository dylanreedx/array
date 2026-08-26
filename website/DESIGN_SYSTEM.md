# Array marketing design system

## Product source of truth

The native Array application defines component geometry, surface hierarchy, state colors, typography, and interaction behavior. Marketing expression may change scale, depth, and masking, but it must not restyle a native component into a generic web card.

The production fixture is `Array 0.5`. Stable IDs connect the Mac and Companion projections. No fixture behavior executes a process, edits a file, or makes a network request.

## Core roles

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| Page | `#f2f3f1` | `#0f1115` | Marketing background |
| Raised page | `#ffffff` | `#171a20` | Header and proof surfaces |
| Ink | `#14171c` | `#f2f4f8` | Primary marketing text |
| Secondary ink | `#54585f` | `#afb6c2` | Supporting marketing text |
| Canvas | `#0b0d10` | `#0b0d10` | Portal and Mac canvas |
| App tile | `#14171c` | `#14171c` | Native tile body |
| App chrome | `#1c212a` | `#1c212a` | Native title bars |
| Working | `#68aef7` | `#68aef7` | Active agents and gyros |
| Attention | `#ffb347` | `#ffb347` | Approval state |
| Done | `#63d596` | `#63d596` | Completed state |
| Failed | `#ff7276` | `#ff7276` | Error state |

System sans is used for every interface and marketing line. System mono is limited to commands, shortcuts, and machine output. No external font request is permitted.

## Type and layout

- Hero headline: `clamp(60px, 7.1vw, 104px)`, 0.9 line height, tight optical tracking.
- Marketing body: 17px to 20px, 1.48 line height, maximum width 620px.
- App metadata is 11px, labels are 12px, body and mono are 13px, titles are 14px to 16px, and major app titles are 18px.
- Touch targets are at least 44px in the active mobile projection.
- Content width: 1280px for reading sections, 1520px for the interactive portal.

## Radius systems

Native radii follow the checked-in `12 → 10 → 8 → 6` ladder. Marketing portal radii use `min(9vw, 140px)` on the leading corner and `min(6vw, 96px)` on the trailing corner. The two systems never trade values. Native boundaries use the app's 0.5px hairline unless a zone requires a 1px semantic stroke.

## Portal, depth, and floating motion

- One asymmetric dark portal is the dominant mass.
- Perspective is 1600px.
- Five detached native surfaces occupy near, middle, and canvas planes.
- Authored resting rotation stays within 4 degrees.
- Detached surfaces receive shallow shadows. Settled surfaces are flat and shadowless.
- The real component tree supplies both detached and settled surfaces. There is no presentation clone tree.
- Each detached surface has its own continuous motion path, duration, negative phase offset, and scale breath. Movement stays within 8px, 0.34 degrees, and 1.8 percent scale variation, then fades to zero as the surface settles.
- Pointer response is animation-frame coalesced and depth-weighted per surface. It contributes no more than 9px translation and 0.8 degrees of rotation, and may move middle planes against the near plane to avoid rigid group motion.
- Ambient surface motion pauses once surfaces settle and under Reduced Motion.
- Product-state motion remains semantic. Gyros animate only for a working agent, approval emphasis belongs only to attention state, and loading motion belongs only to active local fixture work.

## Assembly phases

| Progress | Phase | Behavior |
| --- | --- | --- |
| 0.00 to 0.18 | Glimpse | Copy dominates and working surfaces touch authored viewport edges. |
| 0.18 to 0.36 | Opening | The portal rises and asymmetric page masks expose the canvas. |
| 0.36 to 0.72 | Assembly | Chrome, sidebar, zones, and tiles converge on native positions. |
| 0.72 to 0.84 | Mac | The complete Mac workspace becomes readable. |
| 0.84 to 0.94 | Companion | Companion advances with the shared pending approval. |
| 0.94 to 1.00 | Ready | Companion docks, Mac returns forward, and the interactive reducer unlocks. |

Scroll progress is calculated once per animation frame. Only transform, opacity, and masking properties respond to progress. Reduced Motion removes the pinned track and renders a settled composition.

## Device presentation

Both devices remain visible through the handoff. The Glimpse phase may show a quiet Companion hardware silhouette while detailed phone content remains deferred until the handoff, protecting first paint. Clicking the receded device changes prominence and interaction ownership without a segmented selector. The first click focuses the device and does not activate a nested control.

Companion follows the checked-in SwiftUI hierarchy: NavigationStack titles, plain agent lists, orange tint, freshness footer, and the native four-item TabView. Do not invent a parallel paired-workspace dashboard header. Mobile starts Companion-first and retains the Mac as a linked panorama. Companion camera changes never update the Mac camera.

## Canvas geometry and layout

- Every Mac camera mutation passes through the shared camera clamp.
- Panning must leave at least 120 screen pixels of workspace content visible on each axis.
- Fit All and keyboard `0` restore the complete workspace immediately.
- Tile resize affordances remain screen-constant through canvas zoom. The active corner target is never smaller than 22 CSS pixels and expands at lower zoom.
- Direct manipulation disables geometry transitions and commits reducer state on release.
- Tidy, Shuffle, Undo, resize settlement, and zone growth use the native spatial easing `cubic-bezier(.16, 1, .3, 1)`.
- Tidy is deterministic, respects zone padding and gaps, and expands a zone only when its members require more space.
- Reduced Motion commits final geometry without spatial interpolation.

## Responsive composition

Desktop above 900px presents the Mac as the primary readable workspace and docks Companion to the trailing side. Tablet between 621px and 900px keeps both devices readable while allowing partial offscreen context.

At 620px and below:

- The header is a single row and yields as assembly progress advances.
- The headline, supporting sentence, download control, requirements, and product surfaces fit the opening viewport without horizontal overflow.
- Floating surfaces use authored portrait targets rather than scaled desktop coordinates.
- Companion is the default interactive focus and remains life-size enough for 44px touch targets.
- Mac remains visible as a contextual panorama behind Companion.
- The ready gate fits within one viewport and never depends on finding a narrow scroll position.

## Interaction rules

Every visible control has a stable `data-interaction-id` resolved by the central contract. A control must perform a reducer action, expose a genuine disabled reason, or be a navigation link with a tested destination. Presentation clones never carry an interaction ID.

Base UI owns the deferred Command Center dialog and its focus containment, dismissal, and restoration. The critical download control uses native HTML so its direct DMG link and keyboard menu work before hydration.

Reveal readiness never owns input. Page scrolling remains active until a deliberate canvas click or keyboard focus changes `inputMode` to `workspace`. While active, a non-passive listener contains wheel and pinch input on the selected canvas. Escape and the in-canvas Done action return ownership to the page.

The reducer owns committed product state. Pointer movement stays transient until release. History is bounded, asynchronous work uses generation IDs, and Reset cancels stale completion by advancing the generation.

The ready gate is deliberately obstructive once per reveal entry. It holds forward scroll, names the available interaction, and offers `Use the workspace` or `Keep scrolling`. Reverse scroll, Escape, activation, and the continue action release the hold so the page cannot become a trap.

## Performance contract

- Server-rendered React HTML contains the one real workspace, hero copy, logo, primary download, and initial floating surfaces.
- No font, image, or framework request blocks the first render.
- Initial JavaScript stays below 70KB gzip.
- Deferred interactive JavaScript stays below 160KB gzip.
- CSS stays below 20KB gzip.
- HTML stays below 45KB gzip.
- Lighthouse mobile and desktop must score 100 in Performance, Accessibility, Best Practices, and SEO on every cold run.
- CLS is zero, Total Blocking Time stays below 50ms, and mobile LCP stays below 1.8 seconds.

Detailed Companion content must not become the initial LCP candidate. The Glimpse state may render its hardware silhouette, but readable Companion content enters only as the assembly approaches handoff.

## Component ownership

- Global marketing tokens and responsive rules live in `src/styles/production.css`.
- Scroll and pointer progress live in `src/lib/assembly-controller.ts` and may only write presentation variables and attributes.
- Product state lives in the demo reducer.
- Camera bounds and deterministic layout live in pure helpers under `src/features/demo/`.
- Mac, Companion, agent, browser, shell, note, and Command Center visuals stay in isolated component modules.
- Every visible control is registered by exact ID or approved prefix in the central interaction contract.

Concept-specific colors, spacing literals, or breakpoint behavior must not bypass the shared roles when an existing token or geometry helper applies.

## Iteration workflow

1. Compare native component changes against the current Swift or SwiftUI implementation.
2. Update shared tokens or geometry helpers before adding component-local exceptions.
3. Test Glimpse, Assembly, Ready, active Mac, and active Companion states.
4. Test light, dark, Reduced Motion, keyboard, pointer, touch, and 200 percent zoom.
5. Run check, unit, production build, Chromium, WebKit, Axe, and both Lighthouse configurations.
6. Update this document when a permanent rule changes and record notable implementation changes in `REDESIGN_NOTES.md`.

## Copy rules

Copy is direct, spatial, and product-specific. It describes visible state, parallel work, native control, and handoff. Avoid generic productivity language, invented affiliation, and em dash characters.

## Prohibited patterns

- No separate static product preview, duplicate demo, clone tree, feature-card strip, or default tutorial panel.
- No eyebrow, section kicker, `NATIVE ON macOS` label, or metadata used only as decoration.
- No segmented Mac and Companion toggle when the devices themselves can be selected.
- No giant radius applied to native app chrome, thick workspace outline, repeated border stack, dotted marketing grid, glow, glass, or ambient movement after surfaces settle.
- No literal letters, emoji, or Unicode approximations standing in for Array glyphs or native control symbols.
- No wheel, pinch, drag, or keyboard input leaking from an active canvas into the page.
