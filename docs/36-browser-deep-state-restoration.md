# Browser Tile Deep-State Restoration

Status: **seed / direction only, 2026-06-17. Lower priority** ("many more items
before this" — Dylan). Captures the idea so it isn't lost; to be specced in a
later session.

## Why

Feature **#3** of the "durable, observable home" arc (#1 = tmux shell persistence,
`docs/34`; #2 = observability sidebar, `docs/35`). When you reopen Continuum, a
browser tile should come back not just to the same URL but to the same *state* you
left it in — scroll position, form input, back/forward history, and (the explicit
edge case Dylan named) ideally with the **Inspect Element / devtools panel still
open**.

## Current state (grounded, 2026-06-17)

- **URL persists** across restart today (the tile restores to the same address).
- Browser tiles are `WKWebView`-backed; profile/session persistence exists
  (see `--browser-restore-state-check`, `--browser-profile-persistence-check`).
- Deeper in-page state (scroll/form/history beyond URL) and devtools-open are
  **not** restored.

## Direction (to refine later)

- **Tier 1 (realistic):** persist and restore `WKWebView.interactionState`
  (Apple's opaque blob covering back/forward list, scroll, and some form state).
  Capture on snapshot/flush alongside the URL; apply on tile restore.
- **Tier 2 (best-effort / likely out of scope):** devtools (Web Inspector)
  open-state. `WKWebView` does not cleanly expose "reopen the inspector to where it
  was"; this may be infeasible or require private API. Treat as best-effort,
  probably **out of scope**, until proven otherwise.

## Open questions (for the elaboration session)

- What exactly does `interactionState` cover on current macOS, and does it survive
  app relaunch (it's process-tied — confirm serialization across launches)?
- Storage: where does the blob live relative to the existing browser session
  store? Size/cost?
- Privacy: form state may include sensitive input — opt-in? excluded?
- Is devtools-open worth any effort, or explicitly dropped?

## Non-goals / sequencing

- Explicitly **after** #1 and #2 — there are many higher-priority items first.
- Devtools-open is an acknowledged edge case, not a requirement.
