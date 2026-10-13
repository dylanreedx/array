# Array website production redesign

## October 13 full canvas and native tile motion pass

The continuous demo now expands into a full viewport canvas, with the native workspace topbar and sidebar sliding into place. Independent elastic landings bring the original hero tiles into the scene. Curved camera paths keep moving within task, provider and approval beats; the board opens a native-style task detail, the editor shows a source change, and terminal checks lead into the final overview. Original hero copy and navigation remain intact.

Agent UI follows the native header, transcript, compact activity row, composer and provider/model/effort footer. The working glyph uses the app's three-node, two-plane orbital geometry and continues while scrolling pauses. It stops for completion, Reduced Motion and offscreen scenes. Board and editor components now follow their native hierarchy rather than the previous note/browser fixtures. All six original article nodes remain mounted.

Mobile task details render outside the camera transform; the narrower editor wraps and follows its edited line while retaining the titlebar. Reduced Motion presents all six cards in ordinary flow, with all board lanes visible. An independent source/fidelity review caught duplicate working indicators, stale status icons, mobile clipping and text raster blur; those were repaired. A React-free gyro model also fixes the development server's TSX preamble error without introducing hydration.

Verification: Astro check passes with no diagnostics, all 86 unit tests and 48 Chromium/WebKit browser checks pass. The browser suite covers full viewport geometry, rendered camera movement, paused-scroll glyph motion, native board/editor states, reversible seeking, stable nodes, mobile readability, theme, keyboard, metadata, no JavaScript and zero axe violations. Production build omits Apple pairing fixtures. Six cold Lighthouse runs score 100 in all categories, with CLS/TBT 0; mobile LCP is 1.217–1.222s and desktop 0.326–0.327s. Current captures and performance evidence are under `.plans/72-launch-night/qa/impact-demo/`.

## Earlier October 13 continuous DOM demonstration

Dylan rejected the scroll-synchronized film because it degraded image quality and broke the relationship between the floating hero tiles and the demo. The replacement reuses the existing mimic agent/tool primitives in one server-rendered scene. The hero tiles settle into their own zone, then a scripted cursor and camera follow the task, providers, approval and tools. Scene state is derived from scroll progress, so seeking and reverse scrolling preserve the same tile nodes. The original hero copy and compact unboxed navigation stay intact. The five original hero float paths remain. The same six DOM tiles remain mounted through all beats; the controller seeks text, camera, cursor, provider selection, approval and terminal output without timers or React hydration. The demo contains no video. “See all of it” lands at the start of the assembled scene. Reduced Motion lays out all six cards in ordinary document flow; a no-JavaScript explanation and download remain readable.

Verification: Astro check has zero diagnostics; 83 unit tests and 40 Chromium/WebKit checks pass. Browser checks cover actual tile and inner-agent identity, direct/reverse/reload equality, typed tasks, menus, approval cursor alignment and click feedback, terminal output, 320px/390px focus readability, dark theme, reduced motion, no JavaScript, metadata and legal routes. Independent native/source review completed. Extra visual captures at 320×568, 390×844 and 768×1024 have no page overflow or console errors in either engine.

Three final mobile and three desktop cold Lighthouse runs each score 100 in all four categories, with CLS/TBT 0; mobile LCP is 1.353s and desktop 0.323s. Initial tests exposed low caption contrast and a small-screen status label below 12px, both repaired. Initial Lighthouse scores were 100 but the strict zero-CLS assertion failed at 0.001699 because controller startup replaced SSR text; matching the opening fixture to the first snapshot repairs it. A fixture-clone annotation initially failed type checking, then was corrected. Final production builds omit Apple pairing test URLs. Evidence is kept in `.plans/72-launch-night/qa/dom-demo/`.

The creation menu is intentionally condensed from the shipped Command Center; the stage illustrates example agent and tool activity without executing anything on the visitor’s machine.

## Earlier October 13 correction (superseded demo)

Dylan rejected the plain hero, rewritten subheading, added eyebrow, outlined navigation and invented scroll-demo UI. Restored the prior floating tile composition and original supporting copy. Navigation now has an unboxed layout and right-aligned GitHub/actions; download buttons are smaller and use a transparent mask derived from the existing Array logo to remove the corner/background fringe.

The assembled demo now shows the native power-tour film rather than a new HTML approximation. Scroll seeks its real cursor/camera workflow in both directions. The source is `.plans/68-launch-film/power-tour-r2/power-tour-1080p.mp4`, with a 43.5-second, 1440px H.264 web derivative that omits the closing title card. Decorative hero components render on the server without hydrating React. Video and poster load as the demo approaches. Reduced Motion keeps the hero text and offers a manually controlled film.

The older interactive Mac/Companion components remain available in source; the current homepage does not activate that simulated interface or advertise Companion availability. The corrections retain metadata, privacy/terms and the build-77 appcast.

Verification: Astro check has zero diagnostics; 75 unit tests and 32 Chromium/WebKit browser tests pass. The 12 homepage browser checks were rerun after removing hydration. Axe reports zero violations at desktop/mobile/reduced-motion positions; 320px, tablet and dark-theme visual checks pass. Three mobile and three desktop cold Lighthouse runs each score 100 in all four categories, with zero CLS/TBT. Mobile LCP is about 1.05s and desktop about 0.28s. An initial browser run lacked the pairing fixture environment; rebuilding with that fixture made both pairing checks pass. The final production build excludes those fixture URLs. An initial performance run exposed unnecessary hydration/poster loading; the final run passes after their removal/deferral.

## Outcome

The previous collection of separate marketing demos was replaced by one production homepage centered on a living Array workspace. Five real product surfaces begin detached around the hero, assemble into the Mac canvas through scroll, demonstrate a synchronized Companion approval handoff, and become interactive without swapping DOM trees or resetting product state.

The homepage now contains only the primary hero and workspace, one closing download call to action, and a minimal footer.

## Major changes

### Marketing and assembly

- Removed the static canvas, navigation, phone, and agent preview components.
- Removed duplicate product introductions, feature cards, eyebrow copy, and the segmented device selector.
- Added the asymmetric portal, deterministic scroll phases, and five staggered floating paths with independent scale, rotation, timing, and depth-weighted pointer parallax.
- Added a sticky ready shelf and interaction gate that prevents visitors from accidentally scrolling past the live demo.
- Kept the primary DMG link functional without hydration and simplified the product download menu.

### Interactive workspace

- Added one reducer-backed Mac workspace with sidebar, canvas, zones, and real agent, browser, shell, and note surfaces.
- Added pan, pointer-anchored zoom, Fit, Tidy, Shuffle, Undo, zone creation, movement, resizing, and tile management.
- Added bounded camera geometry so the complete workspace cannot be lost offscreen.
- Added screen-constant tile resize affordances and animated deterministic layout settlement.
- Added Command Center, scripted agent lifecycle, local browser history, safe shell commands, editable notes, and mirrored approval state.
- Rebuilt Command Center against the native AppKit source: 660px upper-aligned frosted geometry, unboxed search, 46px rows, real category sections, attention-first results, provider-grouped model selection, native density, compact shortcuts, and nested Escape and Backspace navigation.
- Added a central interaction contract and automated no-dead-control audit.

### Companion

- Rebuilt Companion around the checked-in SwiftUI NavigationStack and TabView hierarchy.
- Added working Agents, Canvas, Approvals, and Settings views.
- Added native orange tint, plain agent rows, freshness status, local read-only camera control, and synchronized approval resolution.
- Made Companion the default mobile focus while retaining the linked Mac panorama.

### Responsive and accessibility

- Added authored desktop, tablet, and portrait floating-surface targets.
- Added a compact single-row mobile header that yields during assembly.
- Contained canvas wheel, pinch, and pointer gestures only after deliberate activation.
- Added keyboard movement, resize, zoom, Fit, Undo, focus restoration, live status announcements, Reduced Motion, and minimum mobile touch targets.

### Performance

- Kept hero copy, logo, download, and initial product surfaces server-rendered.
- Kept assembly progress framework-free and limited scroll frames to presentation variables.
- Deferred detailed Companion content until handoff so it cannot become the mobile LCP candidate.
- Used system fonts and local SVG assets only.

## Verification recorded August 25, 2026

- `pnpm check`: passed with no diagnostics.
- `pnpm test`: 58 tests passed.
- `pnpm build`: passed.
- `pnpm exec playwright test --workers=2`: 34 Chromium and WebKit tests passed.
- `pnpm test:lighthouse`: three mobile and three desktop cold runs passed every configured assertion.
- Lighthouse desktop final runs scored 100 in Performance, Accessibility, Best Practices, and SEO with CLS 0 and TBT 0ms.

The verification machine used Node 25.9.0 and emitted the expected engine warning because the project requires Node 22.x. Repeat release verification under Node 22. Native Safari gesture and compositing review remains a manual release step.

## Future iteration rules

- Preserve the single workspace tree. Do not restore a static preview or clone layer.
- Treat the native Mac and iOS source as the component authority.
- Keep Companion marked Coming soon until the product status changes separately.
- Preserve the current DMG URL and `public/appcast.xml` unless a release task explicitly changes them.
- Update `DESIGN_SYSTEM.md` for permanent rules and this file for meaningful implementation history.
