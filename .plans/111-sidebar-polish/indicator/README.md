# Active indicator review

Internal startup defaults key: `SidebarActiveIndicatorStyle` (`current`, `gradient`, `halo`, `inset`). Missing/unknown values retain the current appearance; production bundles ignore the key. For a dev launch pass `-SidebarActiveIndicatorStyle halo` as launch arguments and restart when changing it. No persistent defaults need to be written.

1. Gradient: the quiet identity wash recovered from `caf22324` (Oct 29), `SidebarOwnershipMotion.fill`, lines 83–98: 15% dark / 11% light, stops at 0, 45%, 100% within a 55%-width reach. Neutral identities retain the original 5% / 3.5% fallback. The historical implementation applied this to every lead; this adaptation applies it to selected/open agents. No historical one-sided border is carried over.
2. Halo: a continuous identity-colour hairline with a soft, evenly distributed halo and a nearly clear centre.
3. Inset: a solid quiet identity tint and inset neutral hairline, giving the active card the feel of a pressed native panel.

All options affect selected and route-active cards. Existing hover, keyboard focus, state decorations, layout, and default appearance remain intact. Uses existing identity palette and text tokens; no new TokenThemed view. No animation is added.

Capture uses the existing `--sidebar-screenshot-check`, temporarily pointed at `SidebarPolishFixtures.rows` with its coloured lead selected; the capture-only source edits are reverted before commit. These are offscreen AppKit renders, not live-window screenshots. Light/dark stills and the contact sheet accompany this file. Full matrix deliberately not run. No installed app or live tmux server touched.

The requested `.plans/106-sidebar-ownership/README.md` and `.plans/88-sidebar-refinements` paths are absent at origin d41dad04 and have no tracked history under those exact paths in the available refs. Gradient recovery instead uses the retained throwaway branch commit above. Stash list was empty; session searches also located sidebar gradient discussion, but the committed drawing is the reproducible source.

Validation: `swift build --product Array` passed for the capture binary. Each of the three screenshot runs produced the requested light/dark selected-card stills, then exited 1 on the same proposal geometry assertion: claimed 50/58pt versus measured 24/32pt. The capture fixture substitution means this is not a clean screenshot-suite pass. Full matrix was not run, as requested. The first build attempt failed because the capture source was edited while compilation was in flight; a subsequent stable-source build passed. Reviewed all six appearances in `sheet.png`; no live-window or accessibility-contrast validation is claimed.
