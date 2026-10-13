# Brand asset evidence

Generated 2026-10-13 from source in `brand/render-directions.mjs` using Playwright Chromium and Sharp. Each direction has four social compositions (OG 1200×630, LinkedIn 1200×627, LinkedIn portrait 1080×1350, X 1600×900), standalone app mockup (1600×900), SVG mark and lockup, and a zone-to-agent-to-approval workflow illustration. Direction 02 uses a light editorial layout with a centered lower capture. Direction 03 uses oversized split type and a large, diagonal slant trail. The workflow is a labeled explanatory diagram, not a claim that it is native UI. Preview all directions in `brand/index.html`.

The app image is a crop from the real captured app frame `.plans/68-launch-film/hero-loop-r3/stills/hero-loop-loop-bar5.3-f270.png`. The crop shows a workspace and real product tiles; it does not add or redraw UI. Captured model selectors are visible in that source frame, so the brand compositions use a crop that excludes the composer footer and those labels.

Palette values in `tokens.json` were checked against `DesignTokens.swift`, including light and dark leaves for surfaces, text, lines, agent surfaces, and accents. Type roles were checked against `Typography.swift`. No Swift build or app launch was run. The social exports were rendered at 2× in Chromium, then downsampled with Lanczos to the target pixel dimensions.

LinkedIn's official guidance recommends a 1.91:1 ratio and 1200×627 for shared images ([LinkedIn Help](https://www.linkedin.com/help/linkedin/answer/a570368)). It permits 4:5 feed images ([LinkedIn Help](https://www.linkedin.com/help/linkedin/answer/a527229/share-photos-or-videos)); portrait exports are 1080×1350. X's current ad guidance recommends 1.91:1 800×418 imagery ([X Help](https://help.x.com/en/business-and-advertising/creative-ad-specifications)); the requested 1600×900 export is a 16:9 campaign crop retained for the launch package.

Visual inspection at 50% caught and corrected a workflow title/diagram collision. Final render dimensions and the corrected workflow composition were checked again after regeneration.
