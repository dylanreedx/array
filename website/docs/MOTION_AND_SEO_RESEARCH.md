# Website motion and SEO research

This is an implementation guide for Array's website launch. It separates observed project behavior, platform guidance, and design recommendations so a later implementation can trace each choice.

## Current website baseline

The production site is Astro with a React demo island. `ProductionLayout.astro` already emits a title, meta description, canonical URL, `og:type`, `og:title`, `og:description`, `og:url`, and an SVG favicon. It currently uses `twitter:card=summary` and has no social image or `og:site_name`. The homepage's `assembly-controller.ts` maps page scroll to named phases and has a reduced-motion branch; the demo island still includes the “Take control” ready cue. Root `robots.txt` and `sitemap.xml` already exist. The task-specific launch requirements in the board snapshot add legal pages, complete social cards, SoftwareApplication JSON-LD, favicon variants, web manifest, and an automated, hand-held demo.

Project references: `website/src/layouts/ProductionLayout.astro`, `website/src/lib/assembly-controller.ts`, `website/src/components/demo/DemoIsland.tsx`, `website/public/robots.txt`, and `website/public/sitemap.xml`.

## Scroll-narrated demo

### Reference behavior and provenance

I opened the current public source assets through Chrome's normal page and `view-source` URLs (no challenge was bypassed): [`scroll.js?v=7`](https://fuckfigma.app/scroll.js?v=7), [`demo.js?v=35`](https://fuckfigma.app/demo.js?v=35), [`story.css?v=40`](https://fuckfigma.app/story.css?v=40), and [`demo.css?v=40`](https://fuckfigma.app/demo.css?v=40). The following are observed in those assets; implementation recommendations are called out separately below.

`scroll.js` defines each scene's progress as `clamp(-sectionTop / (sectionHeight - stickyStageHeight))`, with a zero-progress fallback if the travel distance is not positive. A passive scroll listener queues at most one `requestAnimationFrame`; each frame renders visible scenes only, skipping sections more than 100px outside the viewport. Because rendering receives the current clamped progress, scrolling upward selects earlier states without a second reverse timeline. The script checks `prefers-reduced-motion` before installing scroll listeners; its scene registration accepts a `still` progress and renders that state immediately when reduced motion is requested.

`demo.js` names weighted steps (`intro`, `pick`, `form`, `open`, `capture`, `langs`, `proof`, `tilt`, `magnify`, `pop`, `across`, `versions`, `focus`, `devices`, `voice`, `store`, `export`, `outro`), sums their weights, converts them to normalized `[start,end]` ranges, and derives the scene height from the total. Captions have independent intervals; their opacity eases in over the first 14% and out over the last 14%, with a 12px vertical offset. Camera keys store normalized progress, a viewport-space center, and zoom; the current key pair is found, eased, linearly interpolated, then applied as one `translate(...) scale(...)` transform. Sparse cursor keys store time, x/y, and visibility; `cursorAt` eases between adjacent keys and click ripples are evaluated at explicit progress points. The demo's reduced-motion still is specifically the `versions` scene near its beginning (`gp("versions", 0.02)`).

The source draws the mock app on a fixed 1440×900 canvas and reframes it, rather than rebuilding the layout per viewport. On widths below 720px, camera measurement uses a smaller margin, a closer-fit scale, and a lower vertical anchor; a `ResizeObserver` remeasures the viewport and queues a render. `story.css` supplies the shared `100svh` sticky stage (with a `100vh` fallback). The mobile CSS changes caption sizing at 720px. The CSS applies `will-change` to the moving camera and cursor, and its comment says that promoting a few dozen full-size layers at 3× had crashed Safari; this is a useful warning to profile promoted layers on phones. The reference does not use a persistent film-grain layer or whole-stage progressive blur: `demo.css` instead uses localized, event-linked accents, including a brief card sweep and a glowing edge pseudo-element whose blur is confined to the active card. Do not copy its visual styling wholesale. Reference home: [fuckfigma.app](https://fuckfigma.app/).

The useful pattern is a *seekable scene*: current scroll progress is the source of truth, rather than a timer or a one-way series of effects. That makes direction changes natural and prevents a scroll-up from leaving an app reducer in a later state. The reference's fake “-50%, you might be eligible” modal is explicitly excluded by the brief.

### Implementation recipe

1. Keep normal document scrolling and a tall story track. Put one stage in `position: sticky; top: 0; height: 100svh` (with a stable fallback for browsers without small viewport units). Give each story beat a named progress interval. Do not intercept wheel, touch, or keyboard scroll, and do not wait at the final beat for the visitor to activate a gate.
2. Define one ordered, typed `STEPS` table. Each entry should include a stable key, normalized `start`/`end`, one reducer action or checkpoint, camera target, cursor path/click point, caption, and optional transition treatment. Keep step boundaries and copy out of rendering effects so the film can be tuned without changing the reducer.
3. Convert the track's scroll position to clamped progress in `[0, 1]`. Read layout once per frame, then schedule a single `requestAnimationFrame` update from a passive scroll listener. Update CSS variables for interpolated camera translation/scale, pointer translation, and opacity. Keep the source of truth as scroll progress so a reverse scroll selects the earlier step deterministically.
4. Make the reducer seekable. Reducer actions such as `OPEN_SHELL` or `REQUEST_APPROVAL` are state changes, not reversible animation values. For this short fixed demo, cache reducer snapshots at step boundaries; when progress crosses backward, restore the appropriate earlier snapshot and replay the short action prefix from the canonical fixture. Interpolate only camera, pointer, and decorative overlay between snapshots. Avoid relying on an effect that fires each action exactly once, because fast scrolling can skip a boundary and reverse scrolling cannot undo it safely.
5. Keep the visible app window at a stable virtual canvas size, then calculate a scale that fits the available stage. Camera keys should name a tile/zone/whole-canvas subject and resolve its bounds from the current demo state. This lets the same scene adapt to desktop and mobile without hand-coded screen coordinates.
6. Give every pointer move and click an explicit progress interval and a target expressed in app coordinates (or normalized coordinates within a target). Transform the pointer with the camera so it stays attached to the intended toolbar button or tile. Make the cursor decorative (`aria-hidden="true"`, no hit testing); reducer actions are scheduled by the story timeline, not actual browser clicks.
7. Keep captions as real HTML text outside the app transform so they stay sharp and readable as the camera zooms. Each caption should describe the change the visitor can see. Do not announce every scroll frame via an `aria-live` region; expose the story as ordered text and use a stable caption for the current beat.
8. Keep a non-animated story path in the DOM: the user can scroll through the captions and key frames with scripts disabled or reduced motion enabled. The release CTA remains a normal link/button after the stage.

Suggested controller shape (pseudocode):

```ts
const progress = clamp((scrollY - trackTop) / trackTravel, 0, 1);
const step = findStep(STEPS, progress);
const state = stateAt(STEPS, step.index); // checkpoint + short deterministic replay
const local = clamp((progress - step.start) / (step.end - step.start), 0, 1);
const camera = interpolate(step.cameraFrom, step.cameraTo, ease(local));
render({ state, camera, cursor: cursorAt(step, local), caption: step.caption });
```

A React `useReducer` can still render the demo. The important contract is that `stateAt(progress)` is a pure, repeatable projection (or uses cached immutable snapshots), so seeking backward and jumping over several beats produce the same result as visiting each beat in order.

### Array storyboard and layout rhythm

This sequence follows the accepted launch-night board storyboard. Captions below are draft direction from that board, not final locked copy.

| Beat | Visible change and layout | Camera / transition | Caption direction |
| --- | --- | --- | --- |
| 1. Workspace | One empty, wide canvas with the floating toolbar visible. | Establish a centered, medium-wide view; let the stage settle before motion begins. | “This is your workspace.” |
| 2. Project zone | Pointer opens Zone from the toolbar; a project chooser appears; a zone lands on the canvas. | Focus on the toolbar, then pan to the new zone. Use a short panel reveal and settle. | “Zones group your work. Each one points at a folder.” |
| 3. First agent | Pointer opens Agent ▾, chooses Claude, and a tile appears in the zone. | Move from toolbar to tile; use a lateral reveal so the zone remains spatially anchored. | “Add an agent from the toolbar, or press ⌘K.” |
| 4. Give it a job | Pointer types a short task and sends it; the tile changes to working. | Close camera framing on composer, then pull back enough to show the working state. | “Give it a job. It works in its own tile.” |
| 5. Run in parallel | Codex and Pi tiles join Claude; all three are visually equal. | Fan into a three-column layout, then hold. The real film's per-agent phase offsets are a useful visual reference if gyros are shown. | “Run several side by side.” |
| 6. Needs you | One tile changes to amber and shows an approval; the status is readable in the tile and sidebar. | Slow camera glide to that tile and a restrained spotlight. Let the change hold long enough to read. | “See who's working, who's done, who needs you.” |
| 7. Tools beside agents | A terminal and browser appear alongside the three agent tiles. | Pan across the workspace, then use the film's short 110ms Tidy move only when demonstrating layout snapping. | “Your tools live next to your agents.” |
| 8. Whole view | Pull out to the whole zone and finish with the download action. | Wide composition, crisp end frame, no modal or forced pause. | “Keep every agent in view.” |

Vary the shot scale and transition rhythm: wide establishing view, close toolbar crop, medium tile framing, three-up layout, a focused approval, a horizontal pan over tools, and a final pullback. Use direct camera glides, short panel slides, staggered card arrivals, a deliberate hold on status, and one tidy settle. Preserve spatial continuity so the viewer can tell which zone and tile each close-up belongs to. Avoid stacking repeated fades; reserve them for elements entering or leaving, while most actions resolve through geometry and state.

### Reusable motion patterns from Array's film work

The canonical launch film at `.plans/68-launch-film/hero-loop-r3/script.md` and the reference worktree `.worktrees/hero-loop/film/` already solve many of the hard motion problems:

- `lib/Lens.tsx` frames a semantic subject and interpolates a lens in output space. It uses exact endpoint interpolation so a scene can return exactly to its starting frame.
- `lib/tracks/camera.ts` uses an exponential camera glide with `CAMERA_TAU = 100ms`; the hero script uses that glide to land focus on the amber approval tile.
- `lib/tracks/tidy.ts` reproduces the website's Tidy position move over 110ms with `cubic-bezier(0,0,.58,1)`.
- `lib/anim.ts` provides named easing curves, seeded deterministic randomness, and closed-form springs that can be evaluated at arbitrary times. The “never restart the spring mid-flight” technique is useful if the cursor or camera retargets.
- `lib/Overlays.tsx` keeps cursor, callout, and key overlays in output space. Cursor paths attach to subjects, fade in/out briefly, and show a small press dip.
- `lib/blur.ts` is a film-rendering temporal blur by subframe accumulation. That is useful for offline renders; it is not a browser recipe for a live scroll demo.

Keep the website implementation smaller than the render factory: reuse the semantic camera, deterministic interpolation, cursor anchoring, status colors, caption placement, and transition timings. Do not port Remotion-only frame hooks or offline accumulation into the browser.

### Progressive blur and grain

Treat blur and grain as transition accents, not permanent decoration. The accepted visual direction asks for progressive/variable blur and a film-like edge treatment; the reference's actual demo avoids whole-stage blur and persistent grain, relying on geometric transforms, opacity, and localized event-linked highlights. For Array, combine those inputs by leaving the app sharp at rest, then using a brief, low-radius blur while changing focus or moving between materially different layouts. A practical starting curve is 0px at settled keyframes, rising to 3–5px near the midpoint of a camera move, then returning to 0px. Blur a contained stage surface, not the full document, and test on mid-range mobile hardware. This numeric range is a starting design recommendation, not a platform limit.

For film grain, use one tiny, static, repeating transparent texture (or a static SVG turbulence image) as a `pointer-events:none` overlay. Mask it with a radial gradient so grain is most visible near the stage edge and fades under the product content. Let its opacity rise slightly during transitions and settle to near-zero at rest. Avoid generating new noise or moving every grain pixel on every scroll frame. Keep grain contrast low enough that text, status color, and focus rings remain clear. These are implementation recommendations inferred from the performance guidance, rather than browser guarantees; they are not behaviors observed in `fuckfigma.app`.

CSS sketch:

```css
.demo-stage__app {
  transform: translate3d(var(--camera-x), var(--camera-y), 0)
             scale(var(--camera-scale));
  opacity: var(--stage-opacity, 1);
  filter: blur(var(--transition-blur, 0px));
}
.demo-stage::after {
  content: "";
  position: absolute;
  inset: 0;
  pointer-events: none;
  opacity: var(--grain-opacity, .035);
  background: url("/images/grain-tile.webp") repeat;
  mask-image: radial-gradient(ellipse, transparent 45%, #000 100%);
}
```

The browser-performance guidance recommends `transform` and `opacity` for smooth animation and warns that properties that trigger paint can be costly. A blur filter can therefore add cost; keep its range and duration modest and profile the actual stage before keeping it. `will-change` should be added only after measurement and removed when the motion ends; unnecessary layer promotion can use memory and hurt performance. See [web.dev's animation guide](https://web.dev/articles/animations-guide) and [MDN's animation performance guide](https://developer.mozilla.org/en-US/docs/Web/Performance/Guides/Animation_performance_and_frame_rate).

### Mobile, reduced motion, keyboard, and performance

Use `prefers-reduced-motion: reduce` as a real alternate presentation. MDN notes that large panning and scaling can trigger vestibular discomfort and that the media query signals a preference to remove or replace non-essential motion. For Array, show one static representative app frame at a time with its caption and story text; disable camera interpolation, scripted cursor travel, blur, grain changes, parallax, and smooth scrolling. Keep the story sequence available as ordinary scroll content. This follows the request for static frames with captions and avoids turning the animation off while hiding the information it conveys. Source: [MDN `prefers-reduced-motion`](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/%40media/prefers-reduced-motion).

Support the user's native scroll input and normal keyboard focus. Captions and download controls must remain reachable without pointer interaction. Do not hijack the wheel or pause scroll at scene boundaries. The story itself is not a keyboard-operable app simulation: it is a narrated preview with a decorative cursor.

On narrow screens, compute the same fit scale from the visible stage dimensions. Keep the whole app frame legible at the first beat; for denser beats, frame a single tile and move vertically/horizontally between subject anchors rather than shrinking every tile until labels are unreadable. Reduce simultaneous surfaces on phone if necessary while keeping the accepted beat order and actual product UI. This is a design inference from the film's semantic lens approach and the requirement for a mobile version.

For performance, animate only `transform` and `opacity` during continuous scrubbing where possible. Read measurements before writes and coalesce scroll work to one animation frame. Keep the actual page headline and first download link in server-rendered HTML so they are available before the React island hydrates. Avoid loading an unneeded full-resolution film into the initial hero; if a video is used, ship a compressed loop, a poster, and delay optional video loading. Do not lazy-load an image or video that is the page's LCP candidate; web.dev warns this delays LCP and recommends making the poster discoverable and prioritized when it is the LCP visual. Profile desktop and mobile, including scroll scrubbing, with Lighthouse and browser performance tools. Sources: [web.dev animation guide](https://web.dev/articles/animations-guide), [web.dev LCP guide](https://web.dev/articles/optimize-lcp), [web.dev lazy-loading video](https://web.dev/articles/lazy-loading-video).

The existing website audit records the launch gate as Lighthouse Performance, Accessibility, Best Practices, and SEO at 100, CLS 0, TBT at or below 50ms, and mobile LCP at or below 1800ms. Treat those as the project acceptance thresholds from `.plans/68-launch-film/research/11-website-audit.md`, not general Google requirements.

## SEO and share metadata

### Page metadata and canonical URLs

Render metadata into the static HTML `<head>` for every indexable route. Astro already supports this in `ProductionLayout.astro`; extend the layout's props/data rather than setting tags after hydration. Every page should have a distinct, human-readable `<title>`, one concise page-specific meta description, and exactly one absolute canonical URL. Align the title, visible main heading, and social title with what the page actually says. Google recommends unique descriptive titles and snippets, and recommends a canonical link in the original HTML rather than changing it with JavaScript. Valid head markup matters because invalid elements in the head can cause later metadata to be ignored. Sources: [Google page metadata](https://developers.google.com/search/docs/crawling-indexing/valid-page-metadata), [Google title links](https://developers.google.com/search/docs/appearance/title-link), and [Google JavaScript SEO](https://developers.google.com/search/docs/crawling-indexing/javascript/javascript-seo-basics).

Recommended route map:

| Route | Canonical URL | Title/content focus |
| --- | --- | --- |
| `/` | `https://arrayapp.dev/` | Array — keep every agent in view; the native macOS workspace for coding agents. |
| `/pair` | `https://arrayapp.dev/pair` | Pair Array Companion; accurately describe the current pairing flow and availability. |
| `/privacy` | `https://arrayapp.dev/privacy` | Array privacy; explain local workspace data and connected CLI accounts. |
| `/terms` | `https://arrayapp.dev/terms` | Array terms; free alpha software terms. |

A canonical identifies the preferred URL; it is not a substitute for a crawlable, useful page. Generate canonical URLs from one configured site origin and the route path so preview hosts never leak into production tags.

### Open Graph and X cards

For each public page emit absolute URLs and consistent text:

```html
<meta property="og:title" content="...">
<meta property="og:description" content="...">
<meta property="og:url" content="https://arrayapp.dev/...">
<meta property="og:site_name" content="Array">
<meta property="og:type" content="website">
<meta property="og:image" content="https://arrayapp.dev/images/array-og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="...">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="https://arrayapp.dev/images/array-og.png">
<meta name="twitter:image:alt" content="...">
```

Use a real 1200×630 image. The launch brief identifies existing candidate art in `.plans/68-launch-film/hero-loop-r3/hero-loop-og.png` and `.plans/68-launch-film/what-is-array-r2/what-is-array-og.png`; inspect which one is appropriate for the current launch before copying it into `website/public/`. Use a distinct alt description of the image, not repeated marketing copy. Keep share image, title, and description coherent across homepage and legal pages, while allowing page-specific titles/descriptions.

The Open Graph protocol defines `og:title`, `og:type`, `og:image`, and `og:url` as its basic object properties, and supports image metadata such as width, height, and alt text. X's current developer documentation now redirects its former card pages to the general docs landing page, so the launch requirement itself pins the requested X field names; X's archived official announcement confirms `twitter:image:alt` support. Sources: [Open Graph protocol](https://ogp.me/) and [X's image alt-text announcement](https://blog.x.com/developer/en_us/a/2016/alt-text-support-for-twitter-cards-and-the-rest-api).

### SoftwareApplication JSON-LD

Add one JSON-LD block to the homepage HTML, with only factual properties that Array can support:

```json
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Array",
  "operatingSystem": "macOS",
  "applicationCategory": "DeveloperApplication",
  "offers": { "@type": "Offer", "price": "0", "priceCurrency": "USD" },
  "url": "https://arrayapp.dev/",
  "downloadUrl": "https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg"
}
```

Google's supported app fields include `applicationCategory` and `operatingSystem`; it specifically says a free app should use `offers.price: 0`. Do not invent an aggregate rating or review to qualify for a rich result. Google's SoftwareApplication rich result requires a review or rating in addition to the app name and offer, and Google does not guarantee a rich result even when markup is valid. Validate JSON-LD with the Rich Results Test, while treating structured data as accurate classification rather than a promise of a special search display. Source: [Google SoftwareApplication structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app).

### Sitemap, robots, icons, manifest, and theme

- Keep `https://arrayapp.dev/sitemap.xml` at the site root and list only canonical, public routes such as `/`, `/pair`, `/privacy`, and `/terms`. Use fully qualified absolute URLs. The current sitemap should be reconciled with the newly added routes.
- Keep `robots.txt` crawl-friendly and include `Sitemap: https://arrayapp.dev/sitemap.xml`. `robots.txt` controls crawler access; it does not reliably remove a URL from search results. Use `noindex` (or auth) if a route must stay out of search. Do not block the JS/CSS needed to understand the marketing page.
- Add a small favicon set with a stable SVG favicon and PNG/ICO fallbacks where useful, plus `apple-touch-icon.png`. Point each link tag at the exact asset path and correct MIME/type and size.
- Add a web app manifest with a meaningful `name`, `short_name`, `start_url`, `display`, `theme_color`, `background_color`, and install icon sizes. The site need not become an installable PWA for the manifest and color metadata to document its brand defaults.
- Keep `<meta name="theme-color">` aligned with the active theme when the site toggles light/dark. The current layout changes it in JavaScript after hydration; also provide a correct initial value in HTML so first paint has a sensible browser chrome color.

Google's sitemap guide recommends absolute, fully qualified URLs and says the sitemap should list the canonical URLs you want indexed. Google's robots guide explicitly distinguishes crawl management from index exclusion. Sources: [Build and submit a sitemap](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap) and [Introduction to robots.txt](https://developers.google.com/search/docs/crawling-indexing/robots/intro). For manifest fields, see [MDN Web App Manifest](https://developer.mozilla.org/en-US/docs/Web/Manifest).

### Privacy and terms copy requirements

These pages are user-facing product facts from the launch brief and should remain accurate to the shipped app:

- **Privacy:** no analytics currently; update checks use `https://arrayapp.dev/appcast.xml`; downloads are hosted on GitHub; agents run through the user's own Claude Code, Codex, or Pi CLI and their accounts; workspace data stays on the user's Mac. Avoid implying that data never leaves the Mac when a user chooses to send a prompt to a provider CLI.
- **Terms:** free alpha software, provided as-is and without warranty; the user is responsible for actions taken by their agents. Contact: the issues page for [`dylanreedx/array-releases`](https://github.com/dylanreedx/array-releases/issues).
- Link both pages from the footer and include both in the sitemap if indexable.

This section reports launch requirements supplied in the project brief; it is not legal advice and is not a substitute for checking implementation behavior before the pages ship.

## Validation checklist for implementation

1. Build the site and inspect the generated static HTML for `/`, `/pair`, `/privacy`, and `/terms`. Confirm one title, description, canonical, OG title/description/url/site-name/type/image/width/height/alt, Twitter large-image card/image/alt, and valid JSON-LD on the homepage.
2. Open every social image URL anonymously; check it is absolute, stable, 1200×630, uses the actual product/brand assets, and has useful alt text. Check with LinkedIn Post Inspector and X's link preview tooling when available.
3. Fetch `/robots.txt`, `/sitemap.xml`, `/site.webmanifest`, favicons, and apple-touch-icon from the built preview. Check sitemap URLs match canonical production routes and robots points to that sitemap.
4. Test the demo by seeking directly to each beat, scrolling down, scrolling back up, rapidly jumping across several beats, resizing, and refreshing mid-story. Verify the reducer state, camera target, cursor target, and caption all match the same progress value.
5. Test normal and reduced motion, desktop and narrow mobile, keyboard focus, and JS-disabled/static fallback. Verify no control is hidden behind the stage and scrolling never gets trapped.
6. Run the existing website acceptance commands (`pnpm check`, `pnpm test`, `pnpm build`) and the project's Lighthouse and axe gates after implementation. This document reports no new runs or validation of the current branch.

## Sources

Primary and standards sources checked for this guide:

- [Google: Software app (`SoftwareApplication`) structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app)
- [Google: Build and submit a sitemap](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)
- [Google: Introduction to robots.txt](https://developers.google.com/search/docs/crawling-indexing/robots/intro)
- [Google: valid page metadata](https://developers.google.com/search/docs/crawling-indexing/valid-page-metadata)
- [Google: title links](https://developers.google.com/search/docs/appearance/title-link)
- [Google: JavaScript SEO basics](https://developers.google.com/search/docs/crawling-indexing/javascript/javascript-seo-basics)
- [Open Graph protocol](https://ogp.me/)
- [X: image alt-text support for Cards](https://blog.x.com/developer/en_us/a/2016/alt-text-support-for-twitter-cards-and-the-rest-api)
- [MDN: scroll-driven animation timelines](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations/Timelines)
- [MDN: `prefers-reduced-motion`](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/%40media/prefers-reduced-motion)
- [web.dev: high-performance CSS animations](https://web.dev/articles/animations-guide)
- [MDN: animation performance and frame rate](https://developer.mozilla.org/en-US/docs/Web/Performance/Guides/Animation_performance_and_frame_rate)
- [web.dev: optimizing LCP](https://web.dev/articles/optimize-lcp)
- [web.dev: lazy-loading video](https://web.dev/articles/lazy-loading-video)
- [MDN: Web App Manifest](https://developer.mozilla.org/en-US/docs/Web/Manifest)

Local project material consulted: `.plans/72-launch-night/BOARD_SNAPSHOT.md`, `.plans/72-launch-night/PROGRESS.md`, `.plans/68-launch-film/hero-loop-r3/script.md`, `.plans/68-launch-film/research/11-website-audit.md`, `.plans/68-launch-film/research/15-movez-motion-course.md`, and `.worktrees/hero-loop/film/lib/{Lens.tsx,anim.ts,blur.ts,Overlays.tsx,tracks/camera.ts,tracks/tidy.ts}`.

### Direct reference-source recheck (2026-10-13)

I fetched the current [homepage](https://fuckfigma.app/) and its linked [scroll runtime](https://fuckfigma.app/scroll.js?v=7), [demo timeline](https://fuckfigma.app/demo.js?v=35), [story CSS](https://fuckfigma.app/story.css?v=40), and [demo CSS](https://fuckfigma.app/demo.css?v=40) over ordinary HTTPS. These first-party files confirm that scroll progress is computed from the section top and sticky-stage travel; a passive listener coalesces updates into one animation frame and skips offscreen scenes. The render function receives current progress, so reversing scroll seeks earlier frames directly.

The demo script defines 18 weighted steps and separate caption intervals, camera keys, visitor/AI cursor tracks, and click points. It draws one fixed 1440×900 app composition, then changes transforms and opacity from progress. A `ResizeObserver` recalculates the fit; the reduced-motion still is near the start of `versions`. The scene mutates presentation DOM directly rather than replaying a reducer. For Array, use the same seekable progress principle while deriving the stable demo state from its fixture; keep all six original tile nodes mounted from hero through the final overview. Use `⌘K` and the shipped Command Center for any creation affordance; do not depict a floating create toolbar, which is not part of the shipped 0.7.26 UI.

At retrieval, the reference uses localized card sweeps and a blurred glow edge, not persistent film grain or full-stage progressive blur. Treat those treatments as a visual reference only. Keep any Array blur/grain contained and transient, and profile mobile Safari before retaining it. The linked assets may change independently of this research note.
