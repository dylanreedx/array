# Night-3 fix tickets (Track A queue + Track B step-0 repairs)

Each item: finding source → required fix → how it gates. Verification convention unchanged: real
checks in `*Checks`/self-check flags wired into `run-matrix.sh`, no XCTest in SwiftPM targets, no
fake-green. Sources: `_CODEX_AUDIT.md`, `_CONFLICT_LOG.md`, and the 2026-07-04 audits of
cc8162b/f546699/ab88bf1/c9fdeb0 (recorded below).

## Track B step-0 (MAIN worktree, FIRST — mobile builds on these)

### B0-1 — FIX ticket 66 ConnectionSupervisor (CRITICAL, audit of f546699)
1. `run()` is a no-op stub (`ConnectionSupervisor.swift:133-137`) — implement the real driver loop per
   the ticket's own breadcrumb design: fire `.retryNow` when `retryAt` elapses (FakeClock-testable),
   subscribe to the socket's `closed` signal → `send(.socketClosed)`. A dropped link MUST move state
   (never wedged `.connected`).
2. Socket leak: `driveIfNeeded(force:true)` on `.networkChanged`/`.wakeup` opens a new session without
   `.close()`ing the live one (`:150-154, :185-253`) — tear down the outgoing socket before publishing
   the new session; add a check that N network flaps leave exactly one live socket/stream.
3. Stability reset is test-only: `lastConnectedDuration` is only set by `simulateConnectedDurationForChecks`
   — measure real connected elapsed (injected clock) so `failureCount` resets after `backoffReset` of
   stable connection; prove with FakeClock.
4. Integrate with the REAL transport surface: drive the supervisor against `ContinuumRevivedSync`'s
   soaked `FakeSyncTransport` (goOffline/reconnect) in at least one check, not only the private
   FakeConnectionDriver; exercise involuntary close end-to-end (close the fake socket, observer detects,
   supervisor reconnects).

### B0-2 — FIX ticket 58 cursor resume (audit of cc8162b) + v1 rule
1. `ActivityProjectionSender.serve()` sends cursor replay events BEFORE the snapshot (`:73-87`),
   inverting the ticket's snapshot-first order; and `ActivityProjectionReceiver.connect(cursor:)` never
   seeds `appliedSequenceByReplica` from the supplied cursor → a fresh receiver resuming from a persisted
   cursor silently discards all replay, flashes an empty board, and forces a full from-0 replay.
   Fix: snapshot-first always; receiver seeds local sequence state from the supplied cursor before
   applying replay. Add the missing check: FRESH receiver + persisted cursor → converges incrementally
   (no from-0 replay, board never empty).
2. Until B0-2 lands, ticket 61 MUST cold-connect (`cursor: nil`) — the tested-safe path.

## Track A queue (worktree `continuum-fixes`, branch `night3/fixes` — codex-primary)

A1 — **23**: finish the `tmuxWindowTarget` migration OFF `TerminalSessionDescriptor` (the to-be-synced
     type) into `ManagedAgentSessionRecord` only; raw-JSON key-absence assertion; Mirror-based (or
     value-based) sync-boundary check instead of the type-name grep (latent I5 — highest priority).
A2 — **21**: call `startReaper` from `attachUI` (the ticket's stated wiring point); the idle gate must
     count PLAIN TERMINAL activity (keystrokes/output), not only AgentStatus.working — use a real
     last-activity source; FakeClock checks: active-shell never reaped, idle session reaped once.
A3 — **22**: implement focused-tile cwd inheritance (read sibling's live `paneCurrentPath` to seed `-c`);
     add the contract's real-tmux backend check ("two distinct alive pane ids").
A4 — **16**: compensating `kill-window` when pane-id capture output is malformed (window created →
     invalid id → must be killed); check covers exactly that path.
A5 — **20**: add the mandated `lastExit`/`releaseLastExitStamped` assertion to the release check with a
     LIVE runtime in the controller; delete the false "controller has no tmux dependency" comments.
A6 — **48**: the four Backend ssh real-path checks per the ticket (loopback sshd; skip-with-loud-note
     if sshd unavailable, never silently green).
A7 — **67**: create `Fixtures/managed-session-with-approval.jsonl` + the real-file integration test
     asserting the 5-step status sequence; align the ComponentLab rows to the ticket's 12-event spec.
A8 — **54 (Dylan's ruling: GRDB NOW)**: add GRDB dependency; PairingStore/SessionStore → on-disk DB
     (0600, real-path check asserts file + perms); constant-time compare in `consume`; `fatalError`
     → `throw AuthError.unscopedMessage`; wire the auth spine into the app path per the ticket's
     "Done when" (terminal spawn passes the session check).
A9 — **38 codex reader** (classified autonomous tonight): same shape as Pi/Claude readers
     (35/36/37); if the `paneStartedAt` capture dep is missing, add it minimally in-ticket; metadata
     only (I5); unblocks 39.
A10 — tails: `setTileZIndex` legacy-Int-throws fixture (04B symmetry); `install()`-clobber regression
     test (03); rename or alias-comment ONE of the two `FakeSyncTransport` types (56 audit: identical
     names, incompatible APIs across Core/Sync — add a doc-comment cross-reference at both, prefer
     renaming Core's to `TransportFakeSyncTransport` if call-site churn is small); `_PROGRESS.md`
     dangling-hash cleanup (authoritative hashes from git log).

## Audit verdicts recorded (2026-07-04, pre-launch)
- 56 ab88bf1 **CLEAR** (soak verified live: 50×200 default + 500×400 CONTINUUM_SOAK=1, oracle + drop
  + partition/heal; nits: silent module substitution Sync-vs-Core FakeSyncTransport (→A10), no CI soak
  leg (repo has no CI — noted, not actionable tonight), watermark deferral now exercised indirectly —
  treated as resolving C-007's deferral, signed off by overwatch).
- 74 c9fdeb0 **CLEAR** (grep gate holds under C-019 amendment; self-check flag-gated; salvage faithful;
  live-verified manifest).
- 58 cc8162b **CONCERNS** → B0-2 (prior two blockers verified fixed — 75/75 green runs).
- 66 f546699 **CONCERNS-critical** → B0-1.
