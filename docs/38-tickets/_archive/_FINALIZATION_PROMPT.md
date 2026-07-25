# Morning finalization — Continuum overnight run

Runs ONCE, when the overnight loop has drained the eligible queue (or hit `MAX_ITER`) **and** there
is fresh Fable/Claude usage (typically after the morning 5h reset). **Local only; NEVER push** unless
Dylan explicitly approves. All final review is done by **Fable**.

## When to trigger
- The loop stopped with `max-iterations-or-complete`, or is quota-sleeping with **no eligible ticket
  left** (every autonomous ticket is done/skipped/blocked), or the queue is otherwise drained.
- AND a Fable call succeeds (usage available). If Fable is still limited, **wait for the reset** — do
  not burn calls; the loop's Codex fallback keeps implementing in the meantime.
- Tree should be clean or hold only known human-owned dirty work (03/04/05). Classify before finalizing.

## Deliverables (produce all, local)
1. **Branch review — Fable, adversarial.** Review `git diff <base>...HEAD` — **base = `main`** (the
   confirmed merge target; Dylan approved `overnight/agent-orchestration → main` AFTER this review).
   Track C (`night3/c-items`) must be merged into the branch BEFORE this review so the diff is complete.
   It's large, so review **by subsystem**: store/protocol seam, op-log/sync envelope, session topology,
   readers/status, injectable substrates, desktop UI/visual (incl. Track C sidebar/dock/managed-tile
   chrome), **and the mobile companion** (iOS app in `ios/`, CloudKit transport, activity projection +
   cursor-resume, APNS push sender + N1–N8 taxonomy, deep-link resolution, approval-over-sync-wire +
   operator scope gate, pairing/GRDB auth). Per subsystem check: correctness, incomplete migrations
   (compat shims defeating a compile-enforced change), tautological/bypassing tests, **I5 taint** (no
   transcript body / secret / host-local data across a sync or activity boundary — extra scrutiny on the
   CloudKit + push payload builders), scope creep, matrix + headless-GUI debt, **device-gate-owed**
   legs (real CloudKit round-trip, real APNS push) that were correctly deferred not faked. Emit
   merge-blocking issues, nits, and risks. **Known open:** B0 ConnectionSupervisor is an honest-skip
   (two attempts stashed) — flag it as the top merge-time caveat, do not treat as done.
2. **PR draft → `docs/38-tickets/_PR_DRAFT.md`** (local, no push): title; summary; per-ticket bullets
   (ticket → commit → what shipped → how verified); **"still owed"** (the supervised full-matrix GUI
   pass — surface checks were skipped headless; blocked tickets 03/04/05/06/07/09 and why); risk
   callouts; requested human-review points.
3. **Visual plan:** consolidate `docs/38-tickets/visual-plan-morning-scope/` into a concrete UI/design
   plan for the shipped + upcoming canvas/agent-orchestration surfaces. Refresh under that dir.
4. **Morning report → `docs/38-tickets/_MORNING_REPORT.md`:** done tickets + commits; skipped/blocked +
   reason codes (from `_CONFLICT_LOG.md`); matrix status incl. headless GUI debt; **Codex-fallback
   commits flagged for Fable audit** (see below); architecture notes; risks; TestFlight/iOS/substrate
   readiness checklist.
5. **Educational PR walkthrough → `docs/38-tickets/_PR_WALKTHROUGH.md` (Dylan explicitly wants this):**
   ~**40 anchored comments** across the run's most vital + interesting areas, each entry:
   `file:line — what this does / why it's done this way / the tradeoff or alternative rejected / what to
   watch when extending it`. Written to TEACH Dylan the branch, not just certify it. Weight toward the
   non-obvious: the schema-migration re-stamp seam, the LWW/tombstone convergence logic, the Op wire
   format + why the transport uses an opaque envelope, the reader I5 boundary, and any subtle
   invariant a future contributor would break. Also weight toward the mobile subsystem's non-obvious
   parts: the snapshot-first cursor-resume seam (B0b — why the receiver seeds appliedSequenceByReplica),
   the CloudKit custom-zone/subscription envelope over the 55 SyncTransport seam, the N1–N8 push taxonomy
   + payload-derived category gating, deep-link resolvePushTap as a pure Core seam, and
   approval-over-sync-wire with the operator scope gate. Aim for genuine insight per comment, not narration.

## Fable audit of Codex-fallback commits (mandatory)
Every commit whose `_PROGRESS.md` row says "gpt-5.5 fallback; pending Fable audit" (cross-ref run
events `codex-fallback-commit`) gets a **real Fable re-review** against its ticket contract. These
landed only through the loop's objective build+matrix gate, not through dual review — Fable is the
review of record. If one is wrong: record why, then propose a fix commit or a revert with rationale
(do not silently revert a landed commit).

## Guardrails
- **No push. No co-author / AI footers. One-ticket-per-commit history preserved.**
- Do **not** touch 03/04/05/06/07/09 logic — human-owned; only report them.
- A huge multi-agent review (fan-out by file/dimension → Fable synthesis) would be stronger for a PR
  this size, but requires Dylan's explicit opt-in — **note the option; do not auto-spawn a Workflow.**
