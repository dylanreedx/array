You are the GPT-5.5 PRIMARY implementer for Continuum NIGHT-3 TRACK A (hardening queue), working in
the dedicated worktree on branch night3/fixes. Implement exactly ONE queue item end-to-end and commit
it. Local commits ONLY — NEVER push. NEVER touch the `ios/` directory (Track B owns it in another
worktree).

STEP 1 — SELECT. Read docs/38-tickets/_NIGHT3_FIX_TICKETS.md ("Track A queue" A1–A10 — THE queue,
strict order) plus, for each item, its evidence: docs/38-tickets/_CODEX_AUDIT.md findings, the
original numbered ticket file (banners included), and the newest _PROGRESS.md rows (rows noting
`night3-A` supersede older rows). Pick the FIRST A-item not yet done (`git log` + ledger) and not
marked skipped in its newest row. If all A1–A10 are done/skipped, print `CODEX_TICKET: none` and STOP.

STEP 2 — IMPLEMENT per the fix-ticket spec. These are REPAIRS to landed code: surgical diffs, don't
rewrite working subsystems. A8 (GRDB) is the only large one — add the GRDB swift package dependency
to Package.swift, migrate PairingStore/SessionStore onto an on-disk 0600 database per ticket 54,
constant-time compare, fatalError→throw.

STEP 3 — VERIFY. `swift build` clean, then `CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh`
ends "Matrix passed". Checks live in `*Checks` executables or flag-wired self-checks wired into
run-matrix.sh (additive lines fine, never weaken). NO XCTest. Real-path checks mean real paths
(real files, real tmux where the spec says so, loopback sshd for A6).

STEP 4 — COMMIT only if green: one item = one commit, plain `type(scope): summary`, NO AI attribution.
`git add -A`, append a `| <item> | done | <hash> | matrix: green (headless) | night3-A gpt-5.5;
pending audit |` row to _PROGRESS.md, fold via `git commit --amend --no-edit`. Print
`CODEX_TICKET: <item>` then `CODEX_RESULT: committed`.
If you cannot make it honestly green: `git reset --hard HEAD && git clean -fd`, print
`CODEX_TICKET: <item>` then `CODEX_RESULT: skipped:<one-line reason>`. NEVER fake-green.
