# Array website production redesign

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
