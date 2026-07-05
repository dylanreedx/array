# Night 3 plan — wrap desktop debt + open the mobile front (2026-07-04 → 07-05)

Goal per Dylan: **wrap up the remaining desktop debt tonight AND get a companion-app build real** —
simulator-verified by morning, TestFlight on his phone by lunch (~15 min of Dylan for the upload).
Window: ~21:00 → ~10:00 (12–15 h). Local commits only, never push, no AI footers.

## Sequencing (evening → morning)

| when | what | who/engine |
| --- | --- | --- |
| ~18:00–19:30 | **P0 prep:** Fable audit of the 4 `gpt-5.5 primary` commits (58/74/56/66 — they're load-bearing for mobile); write Track A fix-tickets + Track B/C amendments; classify 38 autonomous | overwatch (Claude) |
| ~19:30–20:00 | **P1 Xcode walkthrough with Dylan:** Apple ID in Xcode, Team confirmed, iOS target scaffolded, Signing & Capabilities → CloudKit container auto-provisioned; (optional) APNS key | Dylan + overwatch |
| ~20:00–20:30 | **P2 companion design pass** → artifact tab 5 becomes the spec 61/62 build from | overwatch |
| ~20:30 | **P3 launch both tracks** (parallel worktrees, below) | — |
| ~20:30–01:30 | **Track A — hardening loop** in worktree `continuum-fixes` | codex-primary (GPT-5.5, zero Claude) |
| ~20:30–08:00 | **Track B+C — mobile + grey build-out** in main worktree | Opus orch · Sonnet impl · Opus+GPT-5.5 review |
| ~06:00 | **merge point:** Track A branch merged/cherry-picked back into main worktree; combined build+matrix | overwatch |
| ~08:00–09:00 | simulator pass, screenshots, archive; morning report + dogfood checklist | overwatch |
| morning, Dylan | 15 min: App Store Connect upload (2FA) → TestFlight; 30–40 min: visual dogfood checklist | Dylan |

**Parallelism rule:** two loops NEVER share a worktree. Track A runs in a fresh worktree
(`../continuum-fixes`, branch `night3/fixes`) because its files (ContinuumRevived core/app) barely
overlap Track B's (new `ios/` dir + ContinuumRevivedSync). If the 06:00 merge conflicts non-trivially,
fall back: land A's commits by cherry-pick in dependency order, matrix after each. If BOTH tracks would
touch the same seam (e.g. Package.swift), Track A defers that file to the merge point.

## Track A — hardening loop (codex-primary, worktree `continuum-fixes`)

Queue in order (all have precise audit findings / rulings; fix-tickets written in P0):

1. **23** finish `tmuxWindowTarget` migration off the to-be-synced descriptor (kills the latent I5) — HIGH
2. **21** wire `startReaper` into attachUI + real activity gate (plain-shell keystrokes must count)
3. **22** focused-tile cwd inheritance + real-tmux two-pane check
4. **16** compensating `kill-window` on malformed pane-id capture (+ check)
5. **20** `lastExit` stamp assertion in the release check
6. **48** the four Backend ssh real-path checks (loopback sshd)
7. **67** `managed-session-with-approval.jsonl` fixture + integration test
8. **54** per Dylan's ruling (GRDB now vs descope — see Decisions)
9. **38** codex reader (classified autonomous in P0; same shape as pi/claude readers) → unblocks 39
10. Tail: `setTileZIndex` legacy-Int-throws fixture; `install()`-clobber regression test; `_PROGRESS` dangling-hash cleanup

Gate: unchanged codex-primary discipline — bash re-runs build+matrix per commit, reverts fake-greens,
medium→high auto-escalation, driver-written skip rows.

## Track B — mobile companion (main worktree, Opus loop, priority order)

Rides the landed spine (55 transport seam · 58 activity projection · 66 connection supervisor · 59/60 scopes).
Substrate gate cleared in P1 (Team + CloudKit container).

1. **60** pairing token model (pure Swift, no substrate)
2. **57** CloudKit transport impl (conforms to the 55 `SyncTransport` seam; container from P1)
3. **61** iOS observer app — SwiftUI, snapshot-then-tail off 58's activity projection, per the P2 design spec
4. **62** approve/deny action — scope-gated per C-20260702-012 (ownership or operator+, never bare `.observer`)
5. **64** deep-link validation
6. **65** notify categories setting
7. **63** APNS push — only if Dylan created the key in P1; otherwise land behind a flag with the send path stubbed at the seam

**Mobile verification convention (amendment, P0):** headless gate = `xcodebuild -scheme <ios scheme>
-destination 'platform=iOS Simulator,…' build` + XCTest-free check target run in the simulator where the
ticket demands logic proof; real-device/TestFlight/push checks are tagged `device-gate-owed` and go on
the morning checklist. Desktop rules unchanged (no XCTest in the SwiftPM targets, `*Checks` only).

## Track C — grey-ticket build-out (main worktree, same Opus loop, after/interleaved with B)

Implement code-complete with headless self-checks; visual proof deferred to the **morning dogfood
checklist** (tag: `visual-gate-owed`). Order:

1. **40** session observer (FSEvents + tmux + reader dispatch) — biggest unlock: frees 41 + 70, feeds the phone live statuses
2. **41** fsevents push watch (immediately after 40)
3. **43–47** sidebar/dock UI (mock rollup → sidebar tree → left dock → toggle width → jump-to-tile)
4. **71/72/73** managed-tile transcript card, approval dock border, waiting-for-input card
5. **17/18** dead-target fallback + cwd policy; **26** upgrade migration; **29** no-mirror real path; **27** grouped view session (then 30, and 28 becomes meaningful)
6. **70** approvals→needsAttention IF 69's seam question is settled by then (else it stays gated on 69)

NOT tonight: **69** ACP driver (design-heavy — design tomorrow), **68** node sidecar (bundling spike),
**49–53** remote/SSH real-substrate passes (loopback checks only), **25** reattach replay (real terminal),
**42** pending Dylan's consent-UX ruling.

## Decisions — RULED by Dylan 2026-07-04

1. **54 auth: GRDB NOW.** Add the GRDB dependency, back PairingStore/SessionStore with the on-disk 0600
   DB per the ticket, fix the non-constant-time compare and `fatalError`→throw, wire the auth spine.
   Rationale: Track B ships pairing (60) — in-memory grants would force re-pairing every relaunch.
2. **42 consent UX: simple first-run consent prompt approved.** Buildable.
3. **APNS: Dylan is creating the key tonight** (walkthrough below). The .p8 NEVER enters the repo —
   store at `~/.continuum/secrets/` (0600); code reads key path + Key ID + Team ID from local config.
   If the key isn't ready by Track B's 63 slot, 63 lands behind the flag as planned.
4. **Parallel worktrees: APPROVED, with a mandatory lifecycle discipline:**
   - Track A worktree is created fresh at launch: `git worktree add ../continuum-fixes -b night3/fixes`
   - it works ONLY on `night3/fixes`; commits stay there until the 06:00 merge point
   - merge = merge/cherry-pick into the main branch + combined build+matrix green
   - THEN mandatory cleanup, same morning: `git worktree remove ../continuum-fixes` +
     `git branch -d night3/fixes` (only after the merge is verified) — no orphan worktrees or branches
     left behind; `git worktree list` must be back to baseline in the morning report.

## Morning deliverables

- Merged branch, combined build+matrix green; morning report + updated sprint map
- iOS observer app: simulator-verified, screenshots, archive ready for upload
- **Dylan's 15-min upload** → TestFlight by lunch
- **Dogfood checklist** (one doc): every `visual-gate-owed` + `device-gate-owed` item with exact
  "navigate here → do this → see exactly this" steps
- Supervised GUI matrix pass (the 5 deferred surface checks) — can fold into the same sitting

## Model-mix directive (Dylan, 2026-07-04 ~23:10 — binding for the rest of night 3)
Target mix: **Fable 5–20%** (orchestration/steering/adjudication ONLY — review may be delegated),
**Codex/GPT-5.5 ~50%** (default implementer at low + independent reviewer + Track A), **Sonnet 5 ~30%**
(hard/creative implementers + thin drivers). ACTION at the next Track B/C iteration boundary:
restart the loop with `CLAUDE_MODEL=fable CLAUDE_REVIEW_MODEL=opus` (Claude-side review → Opus;
Fable keeps only the orchestrator seat). Codex-fallback overflow on Claude limits stays on.
