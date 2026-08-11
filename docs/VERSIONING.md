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
| 0.4.2   | 8     | 2026-08-11 | `v0.4.2` | Completes the 0.4.1 codex context-meter fix. 0.4.1 read codex's `token_count`, which exists only in codex's rollout log — `codex exec --json` emits thread.started/turn.started/item.completed/turn.completed and nothing else — so the handler never fired and the ring lost its fill entirely (bare "15.1k"). `turn.completed.usage` is cumulative for the session (measured 15,005 then 30,026 across two turns), so occupancy is now the per-turn DELTA, with the baseline carried on the record so it survives a runner process that lives for one turn. A resumed thread with no stored reading publishes no occupancy rather than the unbounded figure. |
| 0.4.3   | 9     | 2026-08-11 | `v0.4.3` | **⌘K is one canonical floating command center.** Entity-first titles instead of raw enum copy, categorized results (Recent, Agents & Tiles, Workspaces & Projects, Actions, Create, Developer), a curated 12-item empty-query home, and typed search that reaches model/status/attention metadata (`gpt 5.6` finds the named session) without that metadata becoming command identity. Needs You comes from the supervisor's real unresolved approval/input request, not an unread heuristic. Recents are outcome-aware: a refused or cancelled selection writes nothing. New Agent drills forward in-card to the live backend-filtered exact model catalogue; Escape restores the root query. The surface is a 660-point floating panel with Solid/Frosted/Glass/Custom appearance (Frosted at 84% by default, bounded custom opacity in Settings), Reduce Transparency forcing Solid and Increase Contrast strengthening the scrim. Dispatch identity is unchanged. **Managed-agent composer completions:** semantic `@` file navigation over a bounded checkout index — fuzzy match, directory navigation, ignore/symlink/deletion handling — accepted as structured file references rather than inserted strings. **Codex context occupancy stops being an estimate.** 0.4.2's per-turn DELTA of the cumulative `turn.completed.usage` is replaced by the exact figure read from codex's rollout log: `event_msg/token_count` carries `last_token_usage.total_tokens` (the prompt on the last request) and `model_context_window` (that request's provider-stated limit), so both halves of the ring come from codex instead of from arithmetic plus pi's catalogue. The runner joins the reading after process exit from a bounded tail read at the byte offset the run started at, and orders it ahead of the terminal event so one coherent final state persists. `codexTurnUsage` is now never occupancy — it stays the row's accounting total only — and records still carrying the old bogus used/max pair are repaired from the rollout on relaunch, or stripped when it is gone. Also: panning the canvas no longer repaints tile chrome. `layoutTile` re-assigns `view.tile` every camera event, which unconditionally marked the title bar dirty, so a trackpad pan re-rasterized every tile's title text on every frame; invalidation is now gated on the drawn value changing (witnessed at 0 redraws across 90 pan steps, while a rename and a zoom past the chrome floor still repaint). |
| 0.4.4   | 10    | 2026-08-11 | `v0.4.4` | **A restored Codex agent shows its transcript again.** Rehydration shipped for Claude and Pi in 0.3.0; the Codex backend landed right after and never got a reader, so `ManagedTranscriptRehydrator` checked only the Claude UUID file and the Pi derived-session file. A native Codex agent matched neither, so the tile rendered the bare "Previous session — send a prompt to continue." notice with no transcript behind it — while the whole conversation sat in codex's rollout log the entire time. Adds exact rollout location by persisted thread id (archived sessions included, ambiguity abstains), rollout JSONL normalized into the existing provider-neutral message model, bounded tail reading behind the existing "earlier history not shown" disclosure, and reconstruction of user, assistant, reasoning-summary and tool-lifecycle items. Display-only like the Claude/Pi path, and the next prompt still resumes the same provider thread. Also: **closed agents are now reachable from ⌘K.** A closed agent has no tile, so the command center's tile-derived rows could never represent one and History existed only in the workspace sidebar; there is now a History section keyed by agent id, ordered last and never volunteered onto the empty-query home, whose membership comes from the same `InboxSort` rule the sidebar's own History header uses. Selecting one reuses the inbox's reveal path whole, so it reopens the record, gives the agent a tile again, clears the unread mark and arms focus in that order. |
