# Overnight execution progress

Durable ledger for the Ralph loop. One row per attempted ticket. Source of truth for "done"
alongside the git log on `overnight/agent-orchestration`.

| ticket | status | commit | matrix | note |
| --- | --- | --- | --- | --- |
| (infra, not a ticket) | done | f42102a | matrix: green | Pre-existing bug found while running ticket 01: `zoneBoundsConfig group8` check in `ContinuumRevivedCoreChecks/main.swift` looked for `paddingKey`/`emptyMinWidthKey`/`emptyMinHeightKey` in the SettingsSchema `"general"` section, but an earlier unrelated commit (1fc7afb, general-settings split) moved those fields to a `"zones"` section — the check called `Foundation.exit(1)` on the mismatch, which silently skipped the entire back half of the check suite on every run, for every ticket, since before this queue started. Fixed as an isolated one-line commit (verified green on clean HEAD before re-applying ticket work). Flagging for morning review since it blocked 100% of the queue and predates this program. |
| (infra, not a ticket) | done | eb7d4fe | n/a | First iteration hit a harness bug: `scripts/overnight-iteration-wf.js` hardcoded the implementer's repo path to the old `continuum-revived` checkout instead of this `continuum-overnight` worktree — the implementer agent correctly refused to fabricate progress in the wrong repo. Fixed as its own commit so future iterations don't hit it. |
| 01-store-protocol-seam.md | done | c71d601 | matrix: green | Implemented cleanly after the harness fix above. Both Opus and Codex gpt-5.5 raised the same scope note (wf.js touched) which was resolved by excluding that file from the ticket commit. Codex also flagged `ContinuumApp.swift:7134` as an unmigrated `ProjectStore` parameter — verified it's a distinct, private, never-called duplicate of `loadOrCreateProject` predating this ticket (dead code, not reachable from any migrated call site), so left untouched per ticket policy. Both reviewers clear after resolution. |
