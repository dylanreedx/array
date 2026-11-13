# Automatic candidate pre-pass (gap 16)

Scheduling remains OFF. No runtime preference enables this worker. The feature
is not integrated or approved for shipping. P1 signature safety was independently
approved on 07df6a85. P2 below is implemented for renewed independent review.

## Host-owned production path

AgentSupervisor.candidateReady(for:task:base:head:) is the explicit host-only
candidate-ready boundary. Its task UUID and full base/head object ids come
from the integration owner, never AgentReport prose. Checkout comes from the
host's child record, and base must equal its host-captured delegation base.
The event mints an immutable candidate UUID. No agent API accepts these inputs.
fileReport consumes only that prepared candidate. Without one, enabled scheduling
records unavailable:identity; it never selects a later HEAD.

The fileReport path enqueues a dedicated utility worker and returns. Admission
is bounded to one job; busy and disabled admissions are explicit outcomes.
Completion updates host state under the report generation and exact candidate.
It neither runs on the launch/provider/hook/ledger queue nor sends notifications.

The existing agent.inspect API consumes the host observation, including exact
candidate/task/base/head, evaluator version and a bounded, labelled advisory
report containing findings/neighbours/unmapped paths. It does not grant merge
permission. AgentSupervisor.reviewCandidate consumes authenticated durable
evidence for the exact host candidate and revalidates live HEAD asynchronously
before returning readiness. Evaluation also revalidates HEAD both before and
after the evaluator. A subsequent merge owner must perform its own final CAS/
revalidation; this change performs no merge.

The production integration owner can now publish an immutable candidate through
this seam. Automatic final-merge workflow scheduling and real-diff p95 remain
unproven and OFF; no report is promoted to verified.

## Authoritative outcomes and failure behavior

Outcomes live under AgentStore.layout.applicationSupportDirectory/
candidate-prepass, within the existing channel-isolated host store, outside
the helper checkout. No .array/prepass JSON is consulted. Both complete and
unidentified admitted attempts produce durable envelopes.

A host-process ephemeral HMAC key authenticates exact encoded outcome bytes.
Inspect reads host memory; review verifies HMAC, candidate identity and the
pinned evaluator version. Modified channel-store bytes cannot forge success.
After restart a new key deliberately makes old records unavailable until rerun.
The disk remains an audit record, not an automatic restart authority.

Atomic-write failures update the observable host outcome to
unavailable:persistence. This memory state overrides an old retained success
for the same candidate id. Evidence reads use no-follow/nonblocking descriptors,
require a regular file and cap bytes before decoding. Missing identity, missing
resources, resource-version mismatch, changed HEAD, evaluator failure, process
limits and persistence failure never become clean.

OFF admission performs no filesystem or evaluator resource lookup. Resource
resolution and package hash verification happen on the worker only. The pinned
SHA256 covers evaluator.py, check-notification-map.py and worker.py. Pattern
dependencies are parsed as source literals: no neighbouring module or Python
bytecode cache is executed. A poisoned-cache positive-control witness reproduced
runtime RED on both 07df6a85 evaluators, then GREEN with source-only parsing.

## Process safety and practical bounds

The host executes the trusted packaged worker.py, never a checkout script.
The controller owns a process group; evaluator and Git descendants stay in it.
Runtime/output breaches kill the whole group. Swift adds a 12s fallback group
kill and group retirement after normal controller exit.

The controller drains stdout and stderr incrementally with a combined 1MiB cap,
8s runtime, inherited 8s CPU and 2MiB file-size limits. Each evaluator Git command
also drains both streams incrementally, with 4MiB combined output and 6s runtime.
Swift captures controller output in a bounded temporary file and reads only
after process exit: there is no detached reader/tail synchronization race.

Darwin's system Python rejects DATA/AS resource limits. A process-group resident
memory watchdog instead samples every 50ms and kills the group above 256MiB.
This is a sampled enforcement threshold, not an instantaneous kernel memory cap.

Git/Python executable paths are absolute, Python uses -I -B, inherited Git
overrides are stripped, global/system configs are disabled, lazy fetch and
replace objects are disabled, and external diff/textconv/fsmonitor/signature
verification are suppressed. The managed crash marker is preserved. No builds,
app launches or tmux occur inside the worker.

## Behavioral witnesses and runtime RED

The app flag --candidate-prepass-check drives real AgentSupervisor.fileReport,
a child created through production delegation, the actual child checkout,
production bundled resource lookup, host completion state, the existing
agent.inspect consumer and the host review action. It covers OFF, explicit
identity, held-worker event delivery, changed HEAD, restart, missing identity/
resources and persistence failure.

Runtime RED before wiring the consumer: a fresh app build retained the original
discarded-completion behavior at fileReport, with the candidate types and app
witness present. The actual app exited 1:
FAIL: production fileReport must consume OFF admission/completion.
The retained-defect patch and run log are at /tmp/prepass-p2-before-consumer.patch
and /tmp/prepass-p2-app-red.log. This is the intermediate production-seam RED;
it is not described as an unchanged 71793931 baseline run. The fix routes
admission/completion through prepassForFiledReport and host observable state.

scripts/check-candidate-prepass.sh compiles the production Foundation source
and exercises exact identity, OFF, authentication, forgery rejection, restart,
missing identity, retained-old-file persistence failure and held-worker bounds.
scripts/check-prepass-process-bounds.py drives the actual packaged controller:
grandchild termination, runtime, stdout/stderr limits, exact output-tail delivery,
inherited CPU/file limits, resident-memory enforcement and both evaluators'
streaming Git output cap.
scripts/check-prepass-signature-safety.py uses malicious local Git signature
config and an actual signed commit object. Both 71793931 evaluators reproduced
runtime RED; both revised evaluators are GREEN, with a positive control proving
the selected signature program really executes without suppression.

scripts/check-prepass-source-patterns.py guards source-only pattern parsing
against a timestamp/size-matched poisoned bytecode cache.

All witnesses are registered in run-matrix.sh. CONTINUUM_PREPASS_ONLY=1 runs
the targeted already-built gate, including the real app flag and an assembled
dev-bundle run via scripts/check-candidate-prepass-bundle.py. That wrapper uses
make-app-bundle.sh --skip-build; it does not touch the shared preview or prod app.
The complete matrix, representative real-diff latency and independent P2 review
remain separate integration requirements. Final observed results belong in the
delivery report; registration alone is not execution evidence.

## Review questions

1. Does the explicit host event plus live HEAD revalidation correctly separate
   advisory inspection from a later review/merge action?
2. Can disk tampering, failed replacement, superseded completion, restart or a
   changed candidate cause clean evidence to attach incorrectly?
3. Are group termination, bounded streams and watchdog enforcement sufficient
   on macOS, given the explicitly sampled RSS threshold?
4. Does the app/bundle witness exercise enough real production ownership to
   establish the consumer fix, with the documented intermediate runtime RED?

No pushes, integrations, provider calls, default tmux access or prod-app changes.
