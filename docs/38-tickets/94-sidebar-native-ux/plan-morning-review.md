# Sidebar — morning review (night 2)

Updated 2026-08-05 after the unattended night-2 hand-drive. Start here. **No owner gate was
marked done and no approval was inferred from silence.**

## Current state

- Branch: `overnight/agent-ux`
- HEAD: `83b10a9` (`feat(sidebar): P4.5 generate names with Pi one-shot`)
- Ledger: **26 of 40 done** (20 at night start; 6 landed overnight)
- Remaining: P3.6; P5.1–P5.6; P6.1–P6.6; P7.1
- Loop: stopped; `docs/38-tickets/94-sidebar-native-ux/STOP` remains armed
- Pushes: none
- Baselines blessed overnight: none
- Owner app launched overnight: no

The loop-control status still reports its interrupted P3.5 run and old `758b7f0` head. That metadata
is stale because night 2 deliberately ran in hand-drive mode; Git and `_LEDGER.md` are authoritative.
Do not remove STOP or restart the loop until you choose the day plan.

## First commands

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
git log --oneline 758b7f0..HEAD
./scripts/check-sidebar-native-ux-program.sh --check
grep -c '| done |' docs/38-tickets/94-sidebar-native-ux/_LEDGER.md   # 26
git status --porcelain
```

Authorized pre-existing untracked work remains: `website/`, root `array-logo*.svg`, Queue 92's
small-team-relay docs/scripts. Night 2 did not touch it.

## What landed

| Commit | Ticket(s) | Result |
|---|---|---|
| `2a6588d` | P3.5 | One status vocabulary across chip/sidebar/tile/phone paths, encoded phone schema and I5 proof, Woke priority preserved |
| `109c17f` | P4.1 + P4.2 | One `New agent` sentinel, identifier migration/defensive read, deterministic first-prompt naming and provenance-safe sync |
| `473a5ad` | P4.3 | Live inline rename behavior plus durable request-id/expected-name compare-and-swap |
| `762c48c` | P4.4 | Explicit → prompt → source item → stable parent-relative ordinal naming across real child-spawn paths |
| `83b10a9` | P4.5 | Ruling R7: explicit generated naming through a bounded, no-session Pi one-shot |

Every final candidate passed the full headless matrix with
`CONTINUUM_SKIP_SURFACE_CHECKS=1 CONTINUUM_SKIP_UI_BASELINES=1`. P4.4 and P4.5 each exhausted the
two-review limit and received a final Luna repair after review round 2; those final repairs have
focused checks plus a green final matrix, **but no third independent review**. Their ledger rows name
the exact findings and witnesses. Those two large persistence/process changes deserve the closest
morning code read.

## Schedule cuts and unfinished work

P4.4's cross-supervisor ordinal persistence and P4.5's bounded-process work took the remaining
schedule. The required cut order was applied rather than weakening checks:

1. P5.5 cut at the 03:30 boundary.
2. P5.4 cut after P4.5 review round 1.
3. P5.2 cut at the 04:15 boundary.

P5.1 and P5.3 were the protected tickets in the schedule, but neither was started before the 05:15
no-new-ticket cutoff. “Cut” means not attempted; all five autonomous P5 ledger rows remain pending.
There is therefore no `qa-runs/p5.6-gate/` yet. See `plan-P5.6-gate-prep.md`.

## Owner gates

### P3.6 — ready for owner review, still pending

Use `qa-runs/p3.6-gate/REVIEW.md` and `qa-runs/p3.6-gate/gate.sh`. Night 2 re-ran:

- preflight: owner instance clear, loop stopped, built-in Retina Main (`display=1`, scale 2.0)
- `swift build`
- `--agent-status-check`
- `--sidebar-ux-check`
- `--agent-inbox-check`
- `--ui-geometry-check`
- `--ui-contrast-check`
- Retina-main check

All mechanical checks were green after P3.5. The real stale-record launch/idempotency walk and taste
questions remain yours. Do not mark P3.6 done until you explicitly approve.

### P5.6 — not ready

P4 naming is present, but P5.1–P5.5 are not. The interaction gate cannot honestly review menu,
filter, bulk, keyboard, and resize as one finished surface. Prep is in
`plan-P5.6-gate-prep.md`; no gate folder or baseline blessing was created.

### P7.1 — not ready

P3.6/P5.6 and all of Phase 6 remain. Prep is in `plan-P7.1-gate-prep.md`.

## Baselines awaiting owner judgment

Nothing was blessed. The final explicit `--ui-baseline-check` reported **22 changed / 38 matched**:

- `chrome.sidebar{,.observerFeed,.live,.selected}` in Aqua and Dark Aqua (8)
- `chrome.activityDock` in both appearances (2)
- `chrome.agentInbox{,.selected,.parked,.shelf,.jumpHints,.bulk}` in both appearances (12)

P3.6's existing REVIEW also records five last-known Component Lab tile candidates:
`managed-agent.approval-dock` (dark), `managed-agent.branch-chip` (both), and
`managed-agent.provider-controls` (both). Re-run both baseline legs during the owner gate; the latest
Component Lab invocation encountered the 22 pending chrome mismatches first, so do not assume the
five tile candidates healed.

Bless only after inspecting candidates with `swift scripts/check-retina-main.swift` green. Never
raise tolerance or bless merely to turn the leg green.

## P4.5 ruling and review focus

R7 supersedes the old R3 block: P4.5 uses `pi`, not `codex exec`. It invokes a cheap model at low
thinking with `--no-session --print --mode text`, no tools/extensions/skills/context, prompt on stdin,
and a strict one-field JSON response. Capability resolution is asynchronous and cached; every shell,
pipe, process-group, timeout, input-failure, and normal-exit path is bounded. Generated/source/prompt
names are replaced by the sentinel at companion sync.

Review especially:

1. P4.4's store-level `flock`, stale-parent high-water merge, and post-rename AtomicWriter recovery.
2. P4.5's `posix_spawn` group ownership, bounded pipe readers, capability cache, and fake-Pi
   descendant/no-session/privacy fixtures.
3. The narrow R2 edits in `ContinuumApp.swift`: wiring/expected-value migration only.

## Retry setting to revert

Night 2 added this temporary resilience block to `~/.pi/agent/settings.json`:

```json
"retry": { "maxRetries": 5, "baseDelayMs": 4000 }
```

`retry.provider.maxRetries` was left untouched. Revert the block when normal provider conditions
return.

## Morning decision order

1. Review/decide P3.6 using `qa-runs/p3.6-gate/`.
2. Choose the P5 implementation order; all P5 tickets remain pending despite the overnight cuts.
3. Run and explicitly approve P5.6 only after P5 is complete.
4. Complete Phase 6, then use `plan-P7.1-gate-prep.md` for final acceptance.

Local commits only; nothing was pushed. The owner decides whether and when to continue.
