# Array website

Production marketing site and interactive product demo for Array. The homepage uses one living React workspace that begins as floating native surfaces, assembles through scroll, demonstrates the Mac and Companion handoff, and becomes interactive at the endpoint.

## Stack

- Astro 7 with static output
- Tailwind CSS 4
- React 19 for the interactive workspace
- Base UI for accessible deferred overlays
- TypeScript
- Vitest, Playwright, Axe, and Lighthouse CI

The page uses system fonts, local SVG assets, and no external runtime services. The demo fixture cannot execute processes, mutate files, or navigate to the internet.

## Local development

Use Node 22 and pnpm.

```sh
pnpm install
pnpm dev
```

The local site runs at `http://127.0.0.1:4321/`.

### Companion download configuration

The `/pair` page reads its public Apple destinations at build time:

- `PUBLIC_ARRAY_TESTFLIGHT_URL` must be an HTTPS `testflight.apple.com` invitation.
- `PUBLIC_ARRAY_APP_STORE_URL` must be an HTTPS `apps.apple.com` listing.

Invalid or absent values are not rendered as links. The pairing invitation is read only from the URL fragment in the browser and is never included in server-rendered HTML or requests.

## Verification

```sh
pnpm check
pnpm test
pnpm build
pnpm exec playwright test --workers=2
pnpm test:lighthouse
```

Every Lighthouse run must score 100 in Performance, Accessibility, Best Practices, and SEO. Static output is written to `dist/`.

## Architecture

- `src/components/ProductionHome.astro` owns the marketing composition.
- `src/components/demo/DemoIsland.tsx` owns the single shared Mac and Companion reducer.
- `src/lib/assembly-controller.ts` owns framework-free scroll and pointer presentation.
- `src/features/demo/` owns fixture data, reducer state, geometry, and the interaction contract.
- `src/styles/production.css` owns global marketing tokens and responsive composition.

Do not introduce a second static demo or presentation clone tree. Detached hero tiles and settled workspace tiles are the same DOM nodes.

## Product and design documentation

- [`DESIGN_SYSTEM.md`](./DESIGN_SYSTEM.md) is the permanent visual, motion, responsive, and interaction contract.
- [`REDESIGN_NOTES.md`](./REDESIGN_NOTES.md) records the production redesign and current verification state.

The checked-in Swift and SwiftUI applications remain the authority for native component styling and behavior. Update the documentation whenever a deliberate website rule changes.
