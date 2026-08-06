# Sidebar — morning review (night 3)

Updated 2026-08-06 after the hand-driven night-3 completion. Start here. **No supervised gate was
marked done, no owner approval was inferred, no baseline was blessed, and no app was launched.**

## Current state

- Branch: `overnight/agent-ux`
- Latest implementation commit: `fe7257d1db93448a335f60a3faaf909dcfb1fb1a`
  (`feat(sidebar): complete accessibility sweep`)
- Ledger: **37 of 40 done**
- Pending: supervised gates P3.6, P5.6, and P7.1 only
- Loop: stopped; `docs/38-tickets/94-sidebar-native-ux/STOP` remains armed
- Pushes: none
- Baselines blessed overnight: none
- Owner app launched overnight: no
- Program guard and final headless matrix: green

Authorized pre-existing untracked work remains untouched: `website/`, root `array-logo*.svg`, and
Queue 92's small-team-relay docs/scripts. The loop-control run metadata still points at the old P3.6
stop; Git and `_LEDGER.md` are authoritative.

## Important: release build failed; a verified debug fallback is available

The required final command was attempted from exact implementation commit
`fe7257d1db93448a335f60a3faaf909dcfb1fb1a`:

```bash
./scripts/make-app-bundle.sh --configuration release \
  --output "qa-runs/night3-candidate/Continuum Revived.app"
```

`swift build -c release` failed. The complete log is `qa-runs/night3-candidate/build.log`. The
failures are Swift strict-concurrency `SendingRisksDataRace` diagnostics in check-only closures at
`ContinuumApp.swift:24801-24802` (`advanceRowCalls`, `advanceBulkCalls`, `advanceHostScript`) and
`:25077-25084` (`undoStore`, `undoRestores`, `undoHostScript`). Per the handoff, source was not
patched for packaging.

A **debug fallback bundle** now exists at the required path:

```text
/Users/dylan/Documents/personal/continuum-overnight/qa-runs/night3-candidate/Continuum Revived.app
```

It was assembled from `.build/debug/continuum-revived`, ad-hoc signed, passed strict deep codesign
verification and plist lint, and was **not launched**. It is not a release build and has no CloudKit
proof. `qa-runs/night3-candidate/STATUS` records its implementation commit, configuration, hashes,
signing state, and `launched=no`.

If Dylan deliberately chooses the debug fallback, the open command is:

```bash
open "/Users/dylan/Documents/personal/continuum-overnight/qa-runs/night3-candidate/Continuum Revived.app"
```

Otherwise fix the release-only diagnostics and rerun the required release command first. Do not
mistake the fallback's presence for release-build evidence.

## What landed in night 3

| Commit | Ticket(s) | Result |
|---|---|---|
| `e2c58fe` | P6.1 | Production row construction now derives lifecycle/variant from records, read-time blockers, descendant hold-open, and the one settlement predicate |
| `ede068c` | P6.2–P6.4 | Real-activity auto-settle, durable snooze/wake, earliest-wake timer, durable read watermarks, production row/menu/bulk actions |
| `13848b3` | P6.5 | Max-8 child fan-out, need-priority survivor exception, explicit expandable remainder, separate descendant attention, nested-fold re-anchoring, full resource accounting |
| `fe7257d` | P6.6 | Native virtual AX hierarchy, exact fact/status ownership, model-boundary announcements, Reduce Motion, Increase Contrast with preserved foreground floors, all new surfaces audited |

P6.1 received a final Sol approval. Slice A, P6.5, and P6.6 each reached the two-review maximum and
ended with narrowly scoped supervisor repairs followed by mutation witnesses and a fresh green full
headless matrix; there was no third review. Their ledger rows record every finding, final repair,
source hash, and exact red witness. P6.6's final matrix-wired accessibility sweep held 2,226 live
assertions across 220/280/320 in Aqua and Dark Aqua.

## Evidence level

At final implementation HEAD, these passed:

- `swift build`
- AgentUI/Core/supervisor/observer/inbox focused checks
- `--sidebar-ux-check`, `--ui-geometry-check`, `--ui-contrast-check`, `--ui-probe-check`, and
  `--agent-inbox-check`
- queue-94 program guard
- `CONTINUUM_SKIP_SURFACE_CHECKS=1 CONTINUUM_SKIP_UI_BASELINES=1 ./scripts/run-matrix.sh`

That is deterministic and headless evidence. It is **not** a live owner-route inspection, an
unskipped GUI matrix, a VoiceOver session, baseline approval, or release-build evidence. The release
build is explicitly red as described above.

## The first real Phase-6 launch is expected to find things

The first launch with Phase 6 wired is the **first time** `.settled`, `.snoozed` and the slim
variant have rendered in the real app rather than in fixtures — two phases of work coming out of the
dark at once. Expect to find things. That is what P3.6 and P5.6 exist to catch, and finding
something there is the gates working, not the night failing.

Do not describe any of those live states as visually verified until Dylan launches and inspects the
exact candidate.

## Owner gates

### P3.6 — materials refreshed; owner walk still pending

Use `qa-runs/p3.6-gate/REVIEW.md` and `gate.sh`. The seven-record stale real-store snapshot remains
preserved, but there is still no `store-after1`, `store-after2`, backup-count pair, or idempotency
output. The exact two-launch stale-store walk, taste questions, and both baseline legs remain owner
work. P3.6 is pending.

### P5.6 — materials now exist; owner walk still pending

All P5.1–P5.5 implementations are present. New materials are in `qa-runs/p5.6-gate/`, and the
tracked overview is `plan-P5.6-gate-prep.md`. The gate must hand-drive menu, filter/search, bulk bar,
keyboard/jumps, resize persistence, naming races, VoiceOver, Reduce Motion, Increase Contrast, and
full keyboard access. P5.6 is pending.

### P7.1 — blocked on P3.6 and P5.6

`plan-P7.1-gate-prep.md` now reflects 37/40 done. Final acceptance still requires an exact installed
candidate, the **unskipped** full matrix, each focused leg five consecutive times, baseline judgment,
and explicit owner acceptance. P7.1 is pending.

## Baseline worksheet

Nothing has been blessed since P1.5. The truthful current worksheet is:

| Action | Count | What |
|---|---:|---|
| Delete after review | 12 | Dead `chrome.agentInbox*-320x652-*` keys; the scope band moved the live height to 660 |
| Judge/bless if approved | 12 | New `320x660` keys with no committed baseline |
| Judge from magenta diff | 10 | `chrome.sidebar*` and `chrome.activityDock*` real changes |
| No action | 38 | Byte-identical chrome renders |

The separate Component Lab leg has five last-known `managed-agent.*` tile candidates; the hairline
explanation remains a hypothesis, not proof. Run both baseline legs again. Bless only after
`swift scripts/check-retina-main.swift` is green on the built-in panel and every candidate is
inspected. Never use the old external-display 1× “38 mismatched” runs as evidence.

## Honest limits to carry forward

- P2.4 was never independently reviewed because protocol failure preceded review.
- Every Phase-5 ticket ended on a supervisor-only repair after the two-review maximum.
- P2.2's `.abbreviated` tier remains unreachable in the P0.3 corpus.
- P3.1's N3 read-only-reinterpret witness was not run.
- No `AgentStatus.failed` exists, so the phone says `idle` where tile/sidebar say `Failed`.
- Several Phase 1–3 checks exercised fixture-only states until Phase 6 made them production-reachable.
- The final release build is red even though the debug build and headless matrix are green.

## First commands

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
git log --oneline caea5b9..HEAD
./scripts/check-sidebar-native-ux-program.sh
grep -c '| done |' docs/38-tickets/94-sidebar-native-ux/_LEDGER.md   # 37
git status --porcelain
sed -n '820,915p' qa-runs/night3-candidate/build.log
```

Then decide whether to fix the release-only concurrency diagnostics before starting P3.6. Do not
remove STOP or restart the loop: the remaining work is explicitly supervised.

## Temporary retry setting from night 2

`~/.pi/agent/settings.json` may still contain:

```json
"retry": { "maxRetries": 5, "baseDelayMs": 4000 }
```

`retry.provider.maxRetries` was intentionally left untouched. Revert the temporary block when normal
provider conditions return.
