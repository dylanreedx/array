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
1. **Branch review — Fable, adversarial.** Review `git diff <base>...HEAD` (base = `main`, or
   `feature/component-lab` if that's the merge target). It's large, so review **by subsystem**: store/
   protocol seam, op-log/sync envelope, session topology, readers/status, injectable substrates, UI/
   visual. Per subsystem check: correctness, incomplete migrations (compat shims defeating a compile-
   enforced change), tautological/bypassing tests, **I5 taint** (no transcript body / secret / host-
   local data across a sync or activity boundary), scope creep, matrix + headless-GUI debt. Emit
   merge-blocking issues, nits, and risks.
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
