# Night-3 fix tickets (compact specs — drivers read this + `_CODEX_AUDIT.md` + the audit rulings below)

Each item: what's wrong (with the audit's file:line evidence), what done means. Same verification
doctrine as everywhere: real checks in `*Checks`/self-check flags wired into the matrix, no XCTest,
no fake-green, one item per commit.

## B0 — FIX ticket 66 ConnectionSupervisor (CRITICAL — blocks all mobile work; main worktree, FIRST)

Audit (2026-07-04, agent report in overwatch log) found four real defects in `f546699`:
1. **`run()` is a no-op stub** (`ConnectionSupervisor.swift:133-137`): nothing fires `.retryNow` when
   `retryAt` elapses and nothing observes `RemoteSocket.closed` → a dropped link leaves the supervisor
   wedged in `.connected` (fabricated state) forever. DONE: `run()` implements the ticket's own
   breadcrumb design — timer race + closed-socket observation driving `send(.socketClosed)`/`.retryNow`;
   a check proves a dropped fake socket transitions to reconnecting WITHOUT any external poke.
2. **Socket leak / duplicate streams on network flap** (`:150-154, :180, :245`): `.networkChanged`
   forces `runAttempt()` even while connected, opening a second socket without closing the first.
   DONE: while `.connected`, network-change signals either no-op or gracefully close-then-reconnect;
   a check counts open sockets across 5 flaps == 1.
3. **Backoff stability reset is test-only** (`:157, :164-166, :252`): `lastConnectedDuration` is only
   set by `simulateConnectedDurationForChecks`. DONE: production code measures connected duration via
   the injectable Clock; reset fires for real; the check uses FakeClock (not the simulate hook).
4. **No integration with the soaked transport**: supervisor invented `FakeConnectionDriver` and never
   touches `ContinuumRevivedSync.FakeSyncTransport`/`SyncTransport.connectionState`. DONE: add an
   integration check driving the supervisor against the REAL `FakeSyncTransport` (`goOffline`/
   `reconnect`), inheriting 56's soak trust.

## B0b — ticket 58 cursor-resume fix + v1 ruling

Audit of `cc8162b`: both prior blockers CLEARED (sync registration + deterministic harness verified,
75/75 green runs). NEW finding: `ActivityProjectionSender.serve()` sends cursor replay BEFORE the
snapshot (`ActivityProjectionSender.swift:73-87`, inverts the ticket's snapshot-first rule) and
`ActivityProjectionReceiver.connect(cursor:)` never seeds `appliedSequenceByReplica` from the supplied
cursor (`ActivityProjectionReceiver.swift:33-41`) → a relaunched app resuming from a persisted cursor
discards every replayed event, flashes an empty board, and forces a full from-zero replay. Zero
coverage (all checks use `cursor: nil` or self-consistent internal cursors).
**V1 RULING (binding on ticket 61):** the iOS app ALWAYS cold-connects (`cursor: nil`) — the safe,
fully-tested path — until this fix lands. FIX (Track B, after B0): snapshot-first in `serve()` for
cursor-bearing requests + receiver seeds local sequence state from the supplied cursor + a check that
constructs a FRESH receiver with a persisted cursor and proves incremental resume without a full replay.

## Notes from the 56/74 audits (both CLEAR; record only)

- **Name collision debt:** two incompatible `FakeSyncTransport` types now exist
  (`ContinuumRevivedCore` ticket-12 substrate vs `ContinuumRevivedSync` ticket-55 actor). The 56 soak
  correctly uses the Sync one; the swap was silent. DEBT: rename the Core one (e.g.
  `FakeTransportSubstrate`) or doc-comment both; grep victims otherwise guaranteed.
- **Soak leg not in the matrix:** `CONTINUUM_SOAK=1` (500 seeds) runs only manually; no CI exists in
  this repo. DEBT: add an opt-in matrix leg or a `scripts/run-soak.sh`; revisit when CI exists.
- **C-007 watermark-race deferral:** treated as satisfied by the soak's adversarial compaction
  coverage (500 seeds, zero divergence) — recorded here as the explicit sign-off trail.
- **Ledger self-hash quirk:** commits that fold their own `_PROGRESS.md` row via `--amend` record a
  pre-amend hash (58's row says `25b7fb5`, real commit `cc8162b`). Known pattern; git log is
  authoritative. Cleanup in Track A tail.

## Track A queue (worktree `continuum-fixes`, codex-primary) — unchanged from _NIGHT3_PLAN.md

A1 **23** finish tmuxWindowTarget migration (audit: field still on TerminalSessionDescriptor —
   remove it, capture seam feeds ManagedAgentSessionRecord only; raw-JSON key-absence check).
A2 **21** wire `startReaper` in attachUI (audit: zero call sites); activity gate must count
   plain-shell keystrokes (not just AgentStatus.working) before detaching.
A3 **22** focused-tile cwd inheritance (read sibling `paneCurrentPath` to seed `-c`) + the real-tmux
   "two distinct alive pane ids" check the ticket mandated.
A4 **16** compensating `kill-window` when pane-id capture returns malformed output + check.
A5 **20** `lastExit`/releaseLastExitStamped assertion with ≥1 live runtime in the release check;
   fix the false "no tmux dependency" comment (`ZoneRuntimeController.swift:85-99`).
A6 **48** the four Backend ssh real-path checks (loopback sshd; spawn wrapped LaunchProfile,
   `tmux has-session`, keepalive, persisted-tunnel decode-then-spawn).
A7 **67** `managed-session-with-approval.jsonl` fixture + integration test decoding real JSON off
   disk through the real Codable path asserting the 5-step status sequence.
A8 **54** GRDB NOW (Dylan's ruling): add GRDB dep, on-disk 0600 DB behind PairingStore/SessionStore,
   constant-time compare in `consume`, `authorize()` fatalError→throw `AuthError.unscopedMessage`,
   wire the auth spine per ticket; real-path check against the actual DB file.
A9 **38** codex reader — CLASSIFIED AUTONOMOUS (2026-07-04): same shape as pi/claude readers
   (35/36/37); metadata only (I5); its `paneStartedAt` dep = ticket 16's capture (landed).
A10 tail: `setTileZIndex` legacy-Int-throws fixture; `install()`-clobber regression check;
   `FakeSyncTransport` rename/doc (from 56 audit); `_PROGRESS` dangling-hash sweep.

## B0-r2 — retry ruling for fix-66 supervisor (overwatch, 2026-07-05 09:40)

The round-3 skip row above IS the diagnosis; this section makes B0 eligible again. The rejected
attempt is stashed as the stash titled "night3 B0 fix-66-supervisor rejected attempt r3" — inspect
with `git stash list` + `git stash show -p <ref>`; do NOT blind-pop (other stashes exist, and the
Auth files have since moved to GRDB in the merged tree). Salvage the 681-insertion structure (real
run() loop with timer race + closed-socket observation, Clock-measured lastConnectedDuration,
FakeSyncTransport integration check) and fix EXACTLY the two Codex concerns:
1. **Explicit wake reason.** run() must distinguish a socket-closed wake from an ordinary
   send() notifyWake(). Replace the shared notifyWake race with a dedicated signal (e.g. an
   AsyncStream of WakeReason, or a closedSocketGeneration counter checked under the actor) so a
   benign `.networkChanged(.online)` while `.connected` can NEVER be misread as socket loss and
   must NOT close the live socket (defect-2 contract: 5 flaps == 1 open socket).
2. **Flap check drives the production loop.** The 5-flap==1-socket check must start
   `Task { await supervisor.run() }` and assert through it — no bypassing run(). Add one more
   check: benign networkChanged while connected → still `.connected`, same socket instance,
   zero `.socketClosed` events observed.
Also note: iteration 3's interrupted B1 pairing attempt is stashed as "night3 B1 60-pairing
interrupted attempt" — that stash belongs to B1, NOT B0; leave it alone during B0-r2.
