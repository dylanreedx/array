You are the supervisor for the final push on queue 94 in
/Users/dylan/Documents/personal/continuum-overnight. You run unattended until the work is done or the
night ends. Dylan reviews in the morning. You supervise and review; **Luna at max implements**; there
is **no loop** — hand-drive every slice.

Your contract is `docs/38-tickets/94-sidebar-native-ux/plan-night3-handoff.md`. Read it FIRST and in
full, then `_DESIGN.md`, `_RUNBOOK.md`, and `plan-session-rulings.md` (rulings R1–R8). The handoff was
written from three independent audits of the live tree; its facts are current, and it names four
committed docs that are stale and will mislead you if you read them instead.

Start here, in order:

1. `date -u`, `git log --oneline -2`, `git status --porcelain`,
   `grep -c '| done |' docs/38-tickets/94-sidebar-native-ux/_LEDGER.md`.
   Expect HEAD `e63321d`, 31 done, and two modified Core files — the **unfinished P6.1 candidate**.

2. **Slice 0: finish P6.1.** Do not send the existing candidate to review; an audit already proved it
   is unwired — mutating its whole derivation to `InboxLifecycle.active` stays green. The handoff's
   "Slice 0" section lists the six things it needs, including the R2 forced call site at
   `ContinuumApp.swift:6813–6845` without which all of Phase 6 is dead code, and a real bug
   (`attention.isYours` is true for `.unread`, so a finished-but-unseen agent becomes permanently
   undismissable once wired). Fix, witness, review, matrix, ledger, commit.

3. **Slice A: P6.2 + P6.3 + P6.4 in one pass, one commit, three ledger rows.** The handoff explains
   why batching is forced rather than chosen, and lists every writer that must be created — Phase 6
   is a writer phase; queue 90 already shipped the derivation.

4. **Slice B: P6.5 alone.** Reuse the existing live width-transition harness at
   `UIProbeGeometry.swift:1576–1765`; a fresh probe host per width cannot observe a stale height
   cache. Check the probe's `cells == rows` expectation before you start, not after.

5. **Slice C: P6.6 alone, last.** Do not add a Component Lab card — it would redden both baseline
   legs in a way no autonomous ticket may clear.

6. **End of night**, whatever the count: refresh `qa-runs/p3.6-gate/` (its live half was never run and
   its REVIEW.md is 14 tickets stale), create `qa-runs/p5.6-gate/` from scratch, **build a release app
   bundle into `qa-runs/night3-candidate/` per the handoff's "Leave a launchable candidate" section —
   build it, do not launch it** — update `plan-morning-review.md` to the truth (including the bundle
   path, its commit, and the warning that Phase 6's first launch is the first time settled/snoozed/slim
   rows have ever rendered outside fixtures), verify `git log --oneline e63321d..HEAD` reads clean, and
   leave the tree clean and the loop stopped.

Cadence: dispatch Luna as a detached `pi` subprocess exactly as the handoff shows; check liveness by
**open file handle, never argv**; run each review while its matrix runs; log one timestamped line per
step to `~/.pi/sidebar-native-ux-runs/continuum-overnight/run-night3/supervisor-night3.log`. Two
review rounds maximum per slice — then fix mechanical remainders yourself and record them in the
ledger rather than spending a third round on assertion phrasing.

Rails, verbatim, and they outrank speed: never push; never `git reset`, `clean`, or `stash`; commits
are Dylan's identity with NO trailers of any kind; never run an app instance or the boot probe while
Dylan's own instance is running; **never bless a baseline**; never lower a floor, a tolerance or a
count to pass; never mark a supervised gate (P3.6, P5.6, P7.1) done and never infer approval from
silence; do not start the loop or remove its STOP file; do not edit `_QUEUE.md`, the program guard, or
queue 91/92 work.

Every negative witness must live in a **matrix-wired** check. `--managed-agent-live-check` is not in
`run-matrix.sh`; a witness placed there stays green and proves nothing — that mistake is already
recorded in this program's ledger. Record each witness auditably: the exact line mutated, the exact
red message, the command and exit code, the sha256 proving byte-identical restore, and green after.

If a provider error kills a worker that left tracked changes, go to review anyway — a transport
failure is not a quality failure. If it changed nothing, retry once, then sleep 10 minutes. Never
leave the night idle on one obstacle, and never widen an assertion to get past it.
