# Pair features receipt

31 October 2026, worker 10, branch `array/col-pair-features` (rebased on
`array/collaboration-finish` at `5b8abb49`). Local relay and background
peers only; no deploy, push, real provider or default tmux server.

## What changed

All eight stages of `scripts/check-collaboration-pair-features.py` were
PENDING. None of these features had ever run between two real Array processes.
Each stage now asserts what the OTHER process shows, read from B's mounted
scene panels or A's recording fake CLI, not re-derived.

| Stage | Card | What B (or the CLI) must show |
| --- | --- | --- |
| liveness | COL-06 | A's host online, then offline (card line "Host offline…") the moment A's host stops, agreement still editable, then online again |
| artifacts | COL-16 | A shares a file tile through the shipped review; its head reaches B on the update stream before B asks; B's artifact panel holds A's exact file bytes and A's content digest; B's checkout unchanged |
| liveViews | COL-15 | B's live panel tails A's running agent ("QA turn accepted and completed."), with no executor or runner call on B, and turns to history when A's host stops |
| freshness | COL-14 | After B's handoff is accepted, B's freshness panel reads Current; A's later edit makes it "Changed since sent"; no second dispatch |
| endorsements | COL-12 | B's endorsement names the agreement's current revision (of at least two); a concurrent stale edit keeps B's draft as a conflict and never overwrites A |
| follow | COL-18 | B follows A's view through two moves (live view centres); B's own navigation ends it; B stays put after; A never follows back |
| compaction | COL-19 | B's reads are held while the relay compacts past B's cursor; released, B resnapshots to an identical document; a peer joining after compaction receives every post |
| harnesses | COL-13 | One extra peer per harness runs that CLI's production runner on `AgentSteeringQAFakes`; B's handoff reaches the Claude, Codex and Pi fake CLI's stdin exactly once each |

## Why they could never have run before (fixed)

1. **Peer transport dropped capabilities.** The peer's fault-injection wrapper
   conformed only to the base controller protocol, so projection calls fell to
   the protocol default (503) and the artifact transport cast failed. It now
   forwards both.
2. **Peer supervisor had no transcript store.** Production passes one; without
   it every projector refuses with `noSnapshotBoundary`.
3. **Peer scene had no freshness model or handoff hook.** The app wired both
   inline in `openSharedArea`. They now go through one
   `SharedAreaHostSession.attach(to:)`, used by the app and the peer.
4. **The pair proxy refused PUT** (Python answers 501), so every artifact blob
   upload failed.
5. **Artifact upload errors were swallowed** (`catch { continue }`).
   `SharedAreaController.lastArtifactUploadError` keeps the cause, which is how
   item 4 was found.

Relay retention for the compaction stage comes from the environment overrides
(`RELAY_COLLABORATION_OPERATION_TAIL` and friends) added earlier.

## Evidence

- `green.log` — one full run: 8 passed, 0 pending, 0 failed.
- `mutants.py` — one product mutation per stage (applied, built, reverted
  inside one lock hold; the tree was clean before each run).
- `mutants-m1-five-red.log` — liveness, artifacts, liveViews, freshness and
  follow each RED on their own assertion. Endorsements and compaction
  SURVIVED that round; both stages were then strengthened (`82dca8ea`).
- `teeth-final.log` — compaction RED, harnesses RED (double execution breaks the
  accepted receipt), endorsements RED after the fix, and the gate.

Gate: see the end of this file.

## Gate

`scripts/run-matrix.sh --collaboration` under `.worktrees/.locks/app-build.sh`,
`CONTINUUM_SKIP_UI_BASELINES=1`, on `82dca8ea`: **12 legs run, passed**
(`gate-summary.txt`). The new leg `python3 scripts/check-collaboration-pair-features.py`
reported 8 passed, 0 pending, 0 failed; the Linux relay leg passed. One note:
the UI-probe surface-cache witness is skipped with the display-dependent legs.
The matrix inventory was not committed.

## Mutant outcomes, final

| Stage | Mutation | Result |
| --- | --- | --- |
| liveness | host stop sends no explicit end | RED: B never reads offline |
| artifacts | controller drops artifact heads | RED: head never reaches B |
| liveViews | projection publish becomes a no-op | RED: B's live view stays unavailable |
| freshness | ledger records no receipts | RED: B never reads Current |
| endorsements | endorse a different revision | RED: endorsement refused (after strengthening) |
| follow | local navigation keeps following | RED: following not ended |
| compaction | client keeps a retired cursor | RED: replicas never converge (after strengthening) |
| harnesses | host executes the dispatch twice | RED: receipt never accepted |

## Still not covered here

Real two-Mac, real relay, real Keychain and real provider CLIs remain Dylan's
(`ALPHA-HANDOFF.md`). The harness stage uses recording fakes, not logged-in CLIs.
