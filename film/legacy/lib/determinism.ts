// Imported first by src/index.ts, before any website module evaluates.
//
// The website's demo is written for a live page: it animates the agent gyro with the Web
// Animations API on document.timeline and eases geometry with CSS transitions. Both run on
// wall-clock time, which Remotion does not control, so a frame would depend on how long the
// screenshot took. Every frame is made a pure function of useCurrentFrame():
//
// 1. The gyro: lib/Film.tsx hands DemoStage a `gyroPhase` (lib/gyro.ts), so every AgentGyro
//    poses itself per frame and never starts its animation loop.
// 2. A film stylesheet removes every CSS transition and animation on the page. Motion the
//    website gets from a transition (Tidy's 110ms native ease) is re-created as a Track.
// 3. Caret and focus rings are hidden: they blink on wall-clock time.
// 4. The agent transcript is painted with its tile, not as a composited scroll layer. It follows
//    the bottom, so its scroll offset grows with every entry. Chrome rasterizes a composited
//    scroller's contents in their own space at the lens scale and moves the result by the offset,
//    so the same visible line lands on a different sub-pixel row once the transcript is a round
//    longer (offset x scale is not a whole pixel), and identical glyphs antialias differently on
//    a looping video's first and last frames. overflow:hidden keeps it a scroll container (the
//    tile still sets scrollTop) that Chrome does not composite; nothing visible changes.
// 5. The sidebar column is pinned at its desktop 280 px. MacWorkspace narrows it with VIEWPORT media
//    queries (205 px under 820 px, min(42vw, 190px) under 620 px), but the film's window is a fixed
//    1380 px whatever the page is. A render tab is briefly 1x1 while Remotion sizes it; the column
//    then collapsed to 0.4 px, the canvas grew to 1378 px, and MacWorkspace's camera clamp
//    dispatched a stray SET_CAMERA (the gate's intermittent failure, first seen at f942 of
//    what-is-array).
const css = document.createElement('style');
css.dataset.film = 'determinism';
css.textContent = `
*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }
:focus, :focus-visible { outline: none !important; }
[data-film-stage] [aria-label="Agent transcript"] { overflow: hidden !important; }
[data-film-stage] [data-assembly-chrome=body]:not([class*="bodySidebarClosed"]) { grid-template-columns: 280px minmax(0, 1fr) !important; }
[data-film-stage] [class*="sidebarInner"] { width: 280px !important; }
`;
document.head.appendChild(css);
document.documentElement.dataset.film = 'true';
