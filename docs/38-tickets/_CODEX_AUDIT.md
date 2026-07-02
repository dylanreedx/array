# Codex-fallback audit — 20 GPT-5.5 commits (2026-07-02)

Adversarial review of the 20 tickets landed unattended by the GPT-5.5/Codex fallback overnight. These
passed only the loop's **objective build+matrix gate** — never the Fable+GPT-5.5 dual review the
Fable-path tickets got. Audited by 8 parallel Sonnet subagents (read-only), each checking its commits
against the ticket "Done when" contract. **None pushed.**

## Verdict tally
- **CLEAR (5):** 31 (closed AgentKind enum), 34 (kind classifier), 35 (reader protocol), 36 (pi reader), 59 (scope OptionSet).
- **CONCERNS (15):** 15, 16, 19, 20, 21, 22, 23, 24, 28, 32, 33, 37, 48, 54, 67.

## Cross-cutting wins (the reassurance)
- **I5 taint: CLEAR** across all readers + auth + a branch-wide new-file grep — the #1 security
  constraint holds. `AgentActivityEvent` carries only a `summary` (hard `precondition ≤500` anti-transcript
  tripwire); readers extract typed metadata only; ticket 36's test writes `SECRET_BODY` files and asserts
  they never reach the snapshot. **One latent exception: ticket 23** (below).
- **No secrets** logged, synced, or committed to fixtures.
- **No XCTest anywhere**; every check is a real matrix-wired `*Checks` executable; no tautological assertions.
- **Naming collision C-009 resolved in code** (all consumers use `ActivityLogSnapshot`); only unbuilt docs drift.
- **The Core logic is almost universally correct.** Failures are in wiring, concurrency, incomplete
  migration, and dropped real-path verification — not algorithms.

## Findings, ranked

### TIER 1 — Merge-blocking functional bugs
1. **Ticket 15 — unbounded tmux window leak on every restart/reboot.** `restartTerminalTile` routes
   project-zone tiles through the `sessionExists ? newWindow : newSession` branch with no check that the
   persisted `tmuxWindowTarget` is still alive, so boot-time restore of every persisted tile creates a
   NEW window and orphans the old one (tmux outlives the app). Quit+relaunch with 3 tiles → 3 orphaned
   windows, repeating every launch. **Still present at current HEAD** (`TileSpawner.swift:262-294`). Highest priority.
2. **Ticket 37 — claude reader reports `.idle` while Claude is actively working.** `deriveStatus` only
   branches on a trailing `assistant` event; when the JSONL tail ends on `user(toolUseResult)` mid-tool-loop
   (common), it falls through to `.idle`. The test meant to catch it appends a trailing `assistant` event,
   so it passes while covering the wrong branch. (`ClaudeAgentStateReader.swift:115-128`.)
3. **Ticket 24 — double-resume race + silent failures.** `recoverManagedSessionOnFocus` has no per-tile
   in-flight guard and `ManagedAgentSessionStore` does read-then-write with no CAS; two quick focus events
   (`.appActivated` + `.userClick` on relaunch) both call `newWindow` → two tmux windows, one leaked, tile
   possibly mis-bound. Separately, the recovery-error notification has **no UI listener**, so the promised
   "honest failure state" never appears.

### TIER 2 — Contract deviations / incomplete deliverables
4. **Ticket 54 — auth not delivered as specified.** Uses in-memory dicts, **not the mandated GRDB/SQLite**
   (ticket says "do not defer it"; no GRDB in `Package.swift`) → pairings/sessions don't survive relaunch.
   No app-layer wiring (zero call sites in `ContinuumApp`). `PairingStore.consume` uses non-constant-time
   `==`/dict-lookup (vs `SessionStore`'s correct HMAC). `authorize()` was silently changed to `fatalError()`
   (contradicts ticket 59, dead `AuthError.unscopedMessage`, DoS vector off a network decoder).
5. **Ticket 21 — idle reaper never wired.** `startReaper` has zero production call sites → the reaper never
   runs. Latent trap once wired: it would re-detach a session while you type in a plain shell tile (plain
   terminal use never sets `.working`).
6. **Ticket 23 — incomplete migration + latent I5.** `tmuxWindowTarget` **still on** `TerminalSessionDescriptor`
   (the type slated to become the synced/observed record) — `%pane_id` now lives in two places; this is the
   exact sync-boundary contamination the ticket exists to prevent (dormant until sync is wired). Backend/
   raw-JSON key-absence check dropped; the sync-isolation test greps for type names, not the leaked value (near-vacuous).
7. **Ticket 28 — depends on unbuilt ticket 27.** The grouped-view-session spawn side never landed, so this
   `kill-session continuum-view-<tileId>` targets a session that was never created → permanent per-close tmux
   warning, zero cleanup benefit. Passes only because the fake has no "session doesn't exist" notion.
8. **Ticket 22 — missing deliverable + fake-backed proof.** Focused-tile cwd inheritance not implemented
   (always uses static ambient root). The required real-tmux backend check ("two distinct alive pane ids")
   was never written — shipped test uses `InMemoryTmuxControl`.

### TIER 3 — Verification gaps (logic correct, required real-path tests dropped)
9. **Ticket 48** — all four Backend/real-path ssh checks missing; only pure-logic assertions. "An ssh-wrapped
   tile actually launches" is unverified.
10. **Ticket 67** — required integration test + fixture (`managed-session-with-approval.jsonl`) don't exist;
    only an inline logic table. ComponentLab dogfood snippet drifts (9 events vs spec's 12).
11. **Ticket 16** — no compensating `kill-window` on malformed pane-id capture (contract requires it); path untested.
12. **Ticket 20** — a false "controller has no tmux dependency" claim (it has `killProjectSessionCommand`)
    defeats the very regression guard the ticket claims; `lastExit` stamp assertion dropped.

### TIER 4 — Minor spec/convention deviations (sign-off, not bugs)
13. **Ticket 32** — added `agentKind == .claude` gate on the hook rung only (contradicts "don't gate on kind"; inconsistent with rungs 1–2).
14. **Ticket 33** — uses `invariantId "…-pure-derivation"` instead of the shared `"I6-status-soundness"` + `via` tag; breaks the convention the next ticket depends on.
15. **Ticket 19** — descriptor lookup is `runtimes.first(where tileId)` instead of `Tile.runtimeRef.id`; safe today by ordering luck, compounds #1's duplicate-descriptor accumulation.

## The meta-finding
Every CONCERNS ticket **passed the objective gate**. The gate structurally cannot see: production wiring
(15, 21, 24, 54), concurrency (24), incomplete migrations (23), dropped backend/real-path test tiers
(16, 20, 22, 23, 48, 67), or test-design blind spots (37). This both validates the fallback (logic is
sound, and it's fast/cheap) and proves the audit was necessary before merge.

## Bookkeeping
The `_PROGRESS.md` commit hashes for these 20 tickets are **pre-amend/dangling** (the fallback's
`git commit --amend` re-hashed each after folding in the progress row). Authoritative post-amend hashes
are in the run `events.jsonl` (`codex-fallback-commit` lines). All code is in HEAD; only the ledger is stale.

## Recommended sequence
1. Fix TIER 1 (15, 37, 24) — real user-visible bugs; 15 is an active resource leak.
2. Decide TIER 2 per ticket: 54 (build GRDB + wire, or explicitly descope pairing persistence for now);
   21 (wire `startReaper` + fix the plain-shell-activity gate before enabling); 23 (finish the field
   migration); 28 (build ticket 27 first, or gate the cleanup); 22 (implement cwd inheritance + real-tmux check).
3. TIER 3 — add the dropped real-path/backend checks (these are the "prove it against reality" tier).
4. TIER 4 — accept or correct the spec/convention deviations.
5. Fix the `_PROGRESS.md` hash ledger from `events.jsonl`.
6. Supervised GUI full-matrix pass (5 deferred surface checks), then decide merge strategy.
