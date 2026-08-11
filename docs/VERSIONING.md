# Versioning

How Array is versioned and the ledger of every shipped release. The release
runbook is `RELEASE.md` (repo root) — follow it exactly when shipping; this
file is the scheme, the rules, and the history. Program history and rationale:
`docs/38-tickets/95-go-live.md`.

## Scheme

Two numbers, two audiences:

- **Marketing version** `X.Y.Z` (`CFBundleShortVersionString`) — for humans:
  release titles, `Array-X.Y.Z.dmg` filenames, the website, release notes.
- **Build number** `N` (`CFBundleVersion`) — a monotonic integer, for Sparkle.
  **This is the field Sparkle compares** to decide whether an installed app
  should update. It increases by exactly 1 every shipped release and is never
  reused or decreased — a repeated or lower build number silently breaks
  auto-update for every installed copy already in the field.

The two move together: every shipped `X.Y.Z` gets the next build number
(0.2.2 was build 4, 0.3.0 was build 5; the next release is build 6).

## Rules

- **Never commit a version bump to `Packaging/Info.plist`.** It stays at its
  dev defaults (0.1.0 / build 1); real versions are stamped at release time by
  `scripts/release-app.sh --set-version X.Y.Z --set-build N`. Why: the repo
  has one source of truth for what shipped (this ledger + GitHub releases),
  and dev builds stay visibly distinct from releases.
- **Both DMG assets on every GitHub release** (`dylanreedx/array-releases`):
  `Array.dmg` — constant name, the site's
  `releases/latest/download/Array.dmg` URL depends on it — and
  `Array-X.Y.Z.dmg` — the permalink the appcast enclosure points at.
- **Regenerate and ship the appcast after every release:**
  `scripts/generate-appcast.sh` rewrites `website/public/appcast.xml` (signed
  with the Keychain EdDSA key); commit it and push to `main`. Why: Vercel
  deploys arrayapp.dev from `main`, and installed apps poll
  `https://arrayapp.dev/appcast.xml` — until it deploys, no one sees the
  update.
- **Archive every shipped DMG in `releases/`** (gitignored, repo root). Why:
  the appcast is generated from it.
- **Never commit:** the Sparkle private EdDSA key (Keychain-only — back it
  up), `releases/`, `.env`, QA stores, signing material.
- **Append a row to the ledger below on every release.** Why: this table is
  how future sessions know which build number is next.
- **Branch topology:** work lands on `array/integration`, fast-forwards to
  `main`.
- **Identity:** the app is Array, bundle id `dev.arrayapp.macos`. Internal
  module names (`ContinuumRevived*`) are deliberately unchanged — never rename
  them; legacy fixtures and historical docs keep saying Continuum. Why: the
  go-live shipped the *external* identity cut only; the source migration is a
  separate, careful program (see the go-live doc's rename history).
- **Git identity:** commits only under Dylan's identity — no AI-attribution
  trailers, no Co-Authored-By.

## Release history

One row per shipped release. Appending here is part of every release.

| Version | Build | Date       | Tag      | Notes |
|---------|-------|------------|----------|-------|
| 0.1.0   | 1     | —          | —        | Dev default in `Packaging/Info.plist`. Never shipped. |
| 0.2.0   | 2     | 2026-08-09 | `v0.2.0` | First public release: notarized Developer ID DMG, arrayapp.dev download button. Pre-Sparkle — these installs cannot self-update and make one final manual download. |
| 0.2.1   | 3     | 2026-08-09 | `v0.2.1` | First appcast-backed release: Sparkle auto-update live (`arrayapp.dev/appcast.xml`), thin-GUI-PATH fix for claude/codex resolution, first-run Environment Setup panel, Help menu (Environment Setup…, Report a Problem…). |
| 0.2.2   | 4     | 2026-08-09 | `v0.2.2` | Provider>model picker (two-pane, t3-ported) in tiles + Settings with display names from pi's catalog; live model catalogue with throttled re-probes; onboarding pi + per-provider auth rows (CLI login only); dev/prod channel split; Settings ▸ Agents default wording. First release colleagues are pointed at. |
| 0.3.0   | 5     | 2026-08-10 | `v0.3.0` | Agent-harness picker (Settings ▸ Agents): managed agents run on Claude Code, Codex, or pi — model list filters to the choice, all on the CLI's own login (never API keys). Codex + Claude Code CLI backends (own-subscription, pi-free); transcript resume rehydrates a tile's prior conversation on relaunch; onboarding "at least one harness" fresh-setup. Fixes: markdown tables render (no more "Unsupported content"), context meter shows token counts for claude/codex, rehydrated tool cards show the command, custom-folder Home updates the header. |
| 0.4.0   | 6     | 2026-08-10 | `v0.4.0` | Closing an agent tile parks the agent in **History** (collapsed sidebar section) instead of leaving an "Unconfirmed" row forever; clicking a History row reopens and resumes the agent. A working agent stays in the live list when its tile closes. Archive became the reversible verb (parks + takes the tile) and Delete the only destructive one. Live status moved onto the prism gyro with a running clock; the footer keeps only attention states and is silent otherwise. The context ring now fills from real per-provider token usage. Drag/paste md/pdf/txt/code onto a composer as `@/path` references. Fixes: an agent whose tile was gone had an unclickable sidebar row. |
| 0.4.1   | 7     | 2026-08-10 | `v0.4.1` | Context meter fix for codex tiles. The ring divided codex's CUMULATIVE session input by pi's catalogue window and read up to 237%; occupancy now comes from codex's per-request `last_token_usage` and the window from the `model_context_window` codex itself reports (258,400 for gpt-5.6-sol, where the catalogue said 272,000). The `token_count` event that carries both arrives repeatedly DURING a turn, so the ring fills while the agent works instead of jumping at turn end. claude/pi unchanged. |
