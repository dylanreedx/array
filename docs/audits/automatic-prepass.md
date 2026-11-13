# Automatic candidate pre-pass

Scheduling remains OFF. CandidatePrepass.shared has no runtime enable switch.
The helper report path submits only host-owned checkout and delegation base.
The worker captures HEAD, verifies full object ids, and evaluates that immutable
range using the evaluator copied into the app's SwiftPM resource bundle.
Missing base/evaluator/objects and evaluator failure are unavailable, never clean.
Reports do not supply revisions. Report, event, hook and ledger paths run no git
or evaluator synchronously. One utility job bounds admission; excess returns false.

Outcomes are atomic JSON in the project's .array/prepass directory. Review
consumption requires an exact checkout/base/head match through reviewOutcome;
a changed head or missing identity cannot reuse an old result after restart.
The report payload includes evaluator findings, manifest version, neighbours and
unmapped paths. There is no existing production review-request or integration
workflow consumer, so that further integration remains open. No verified stage,
notifications, builds or check execution is inferred.

The packaged evaluator is versioned with the app. Git and Python paths are
absolute, Python is isolated, checkout scripts are never launched, git external
diff/textconv/fsmonitor are disabled, and inherited Git overrides are removed.
The managed crash marker is retained. Processes have 10s parent runtime and
1MiB captured stdout limits; evaluator git children have 8s timeouts.
No tmux is used. This does not establish representative p95 or zero added
wall time: those measurements and sibling review are required before enabling.

Witness: scripts/check-candidate-prepass.sh compiles the actual production
Foundation source with a fixture driver, creates disposable committed ranges,
and checks OFF, explicit range, nonblocking admission while evaluator is held,
bounded admission, durable outcome, exact restart matching, changed-head
rejection, missing identity and evaluator errors. Registered in run-matrix.sh.
Full app compilation and a full matrix run are separate integration gates.

## Validation and review handoff

Baseline 83993fa5 has no CandidatePrepass production entry (git show reports
the path missing). This is an absent-seam RED, not a demonstrated baseline
runtime failure. The witness also deliberately invokes a missing evaluator
and requires its failure before running the real evaluator.

Ran the original script fixture: 44 passed, 0 failed. Ran the same fixture
against the packaged evaluator: 44 passed, 0 failed. The first worker compile
succeeded, then the runtime witness failed "evaluated": its repository lacked
the manifest, and the packaged evaluator lacked its neighbouring sender-pattern
module. Both fixture/resource defects were corrected. Several subsequent build
attempts were refused by the required four-build resource gate. Final worker witness then passed: missing evaluator rejected; OFF, explicit range,
durable outcomes, missing identity, exact restart/head matching, held-worker
nonblocking admission, bounded admission and evaluator error outcomes all GREEN.

No full app build, full matrix report, bundle harness, UI, provider, tmux,
or representative timing runs. The matrix leg is registered but has not been
observed in a full matrix summary. Existing managed crash marker was preserved.
The bench inventory ran at pickup and final inspection; this worktree remains
for independent review and landing.

Lead should obtain sibling review (child review depth is blocked):
1. Does host delegation base + worker-captured HEAD form an adequate candidate
   boundary for helper reports, with no reliance on prose?
2. Can local Git config, a textconv, or a missing resource execute checkout
   code or turn an unavailable result into clean?
3. Are pipe draining, timeout, admission and durable exact-identity matching
   sound, including a changed head and restart?
4. Should the later integration owner supply an explicit head at its owned
   merge seam instead of using the report seam's host capture?
