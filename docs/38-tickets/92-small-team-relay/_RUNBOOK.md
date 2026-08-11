# 92-small-team-relay — operating and supervision contract

## Program boundary

This program has its own queue, ledger, fresh-worker loop, review loop, control surface, and external artifacts. It consumes the provider-neutral agent content/runtime seams built by queues 90/91 but may not repair or absorb queue 91 work.

Read in order:

1. `_DESIGN.md`
2. `_DECISIONS.md`
3. `_ACTION_ITEMS.md`
4. `_RUNBOOK.md`
5. `_QUEUE.md`
6. `_LEDGER.md`
7. the selected packet

`plan.mdx` is retained local context, not a mutable hosted dependency. Where it conflicts with `_DESIGN.md` or `_DECISIONS.md`, the local design/decisions win.

Exactly one ticket is implemented per iteration and per local commit.

## Preconditions before any loop start

- Branch is `array/integration`. The loop never creates or switches branches.
- Queue 91 is stopped, its preserved P4.6 candidate is recorded as superseded by the landed repair/integration commits in `_ACTION_ITEMS.md`, and no other implementation/review child is alive.
- The working tree/index are clean except owner-authorized untracked `website/` and root `array-logo*.svg`.
- This program's preparation files have been reviewed and committed separately before the implementation loop runs.
- `docs/38-tickets/92-small-team-relay/STOP` is absent.
- `swift build`, RelayProtocolChecks, RelayChecks, RelayIntegrationChecks, and the current matrix are green once each target exists.
- Pi exposes authenticated `openai-codex/gpt-5.6-sol` and `gpt-5.6-luna`; workers alternate at medium thinking and the opposite model performs read-only review.
- Owner prerequisites due before the next supervised gate are recorded in `_ACTION_ITEMS.md`; no secret is placed in the repository.

Never set `ALLOW_DIRTY=1`. A loop is an exclusive writer to this checkout.

## Locked implementation rules

- One trusted relay serves a small team; no public multi-tenant platform.
- RelayProtocol is transport/platform neutral; RelayCore owns durable state/auth; RelayNIO owns sockets; execution hosts own provider/runtime truth.
- Persist before broadcast.
- Generic `SyncMessage` is not the privileged full-control protocol.
- Class A push is sanitized, Class B requires typed authenticated workspace authorization, Class C remains host-only.
- Device/environment credentials are server-generated, hashed at rest, expiring/revocable, and never accepted in URLs.
- Workspace/capability authorization and operation limits are deny-by-default.
- Commands are idempotent and serialized per agent; ambiguous provider dispatch is `indeterminate`, never blindly replayed.
- Private-network/loopback is first; wildcard/public bind requires owner decision.
- SQLite WAL and local blobs remain the single-node authority; no distributed-service substitutions.
- Actual Mac sleep suspends local work; only another awake host continues.
- No executable HTML/WebView transcript content.
- No matrix/gate/limit/privacy denial is weakened to make a ticket pass.
- Real-route claims require real process/device/network artifacts; confidence is not evidence.

## Ticket selection

The harness selects the first `_QUEUE.md` row whose dependencies are all `done` and whose ledger state is `pending`.

- `done` requires ledger state and a matching harness-owned local commit.
- `blocked` is never retried automatically.
- `supervised` stops the loop; no later ticket may be selected.
- Workers cannot select tickets or edit queue, ledger, design, decisions, action items, packets, prompts, or loop machinery.

## Per-ticket workflow

1. Harness selects one eligible autonomous ticket and records state outside the repository.
2. One worker reads the packet/design/compiled seams, captures named RED evidence, implements only fenced production/check files, runs focused checks plus `swift build`, and returns `WORKER: READY` or concrete `WORKER: BLOCKED`.
3. Harness rejects worker commits and out-of-fence paths immediately.
4. Opposite GPT-5.6 Sol/Luna model performs one bounded read-only review for correctness, architecture, security/privacy, file scope, TDD evidence, and done criteria.
5. At most two focused repair passes are allowed, each followed by independent re-review. A third `REWORK` stops with work preserved.
6. After approval, harness runs `swift build` and the full headless matrix exactly once against the final candidate.
7. Harness alone updates exactly one ledger row, stages validated paths, and creates one local `feat(relay): …` commit. It never pushes.
8. Malformed output, provider failure, failed final check, worker commit, scope violation, exhausted review, missing external prerequisite, or dirty tree stops with work preserved.

## TDD and verification integrity

Every autonomous packet must leave durable evidence for:

1. **RED:** the approved expected behavior fails against the pre-change production seam. Never alter an old expectation solely to manufacture this failure.
2. **Implementation:** only the packet file fence changes.
3. **GREEN:** focused production-seam checks and `swift build` pass.
4. **Mutation witness:** mutate the final implementation to reintroduce the named failure, observe the normal focused check red, restore exact bytes/hash, and rerun green.
5. **Independent review:** opposite model returns `DECISION: APPROVE` on the complete diff.
6. **Final matrix:** harness-owned and run once after approval.

A check changed in the same patch is not independent proof. The pre-change RED artifact plus final-code mutation witness makes the check falsifiable. Do not claim `working`, `fixed`, or `end-to-end verified` beyond the evidence level actually run.

### Deterministic testing rules

- Inject wall/monotonic clocks, entropy, filesystem roots, APNs transport, store faults, and network scheduling.
- Use temporary directories and SQLite files; reopen actual files for durability tests.
- Use loopback port `0`, readiness records, bounded tasks, and explicit barriers; avoid fixed ports and sleeps.
- Use seeded fuzz with printed replay seed; never unseeded randomness.
- Run malformed/oversized/depth/count payloads through the real decoder/router.
- Exercise two workspaces, devices, environments, and resource-substitution attacks.
- Scan argv, stdout/stderr, logs, metrics, errors, backup manifests, push payloads, and qa artifacts for fixture secrets/Class-B bodies.
- Do not lower counts, limits, fault points, or time/space floors to make a candidate pass.

### Check layers

Fast pure:

```bash
swift run ContinuumRevivedRelayProtocolChecks
```

Real SQLite/core:

```bash
swift run ContinuumRevivedRelayChecks
```

Real process/sockets/config/service contracts:

```bash
swift run ContinuumRevivedRelayIntegrationChecks
```

Repository final gate:

```bash
swift build
CONTINUUM_SKIP_SURFACE_CHECKS=1 CONTINUUM_SKIP_UI_BASELINES=1 ./scripts/run-matrix.sh </dev/null
```

The worker runs named focused checks and `swift build`; the harness runs the final matrix. Physical phone, APNs, external sleep witness, target-host soak, real backup custody, public/private route, and actual Linux deployment remain supervised.

## File-fence rules

`## Files` is exhaustive for the selected packet. The loop supports exact paths and a single filename wildcard whose match cannot cross a directory. A compile-enforced direct call site outside the fence is a block until a coordinator narrows/updates the packet; it is not permission for the worker to roam.

Never absorb:

- dirty queue-91 candidate files;
- unrelated app/visual/FileTree/provider work;
- root logos or `website/`;
- hosted plan updates;
- broad formatting/renames;
- a second architecture.

## Git discipline

- Local commits only; never push.
- No branch switch, merge, rebase, reset, clean, stash, worktree creation/removal, or history rewrite from the loop.
- Workers/reviewers never stage or commit.
- One harness-owned commit per ticket plus one targeted ledger row.
- Existing unrelated tracked changes are a hard preflight stop.
- Authorized untracked `website/` and root logos remain unstaged.

## Loop control

Use the dedicated control surface after the program preparation is committed and queue 91 is not active:

```bash
./scripts/small-team-relay-loopctl.sh arm
./scripts/small-team-relay-loopctl.sh start
./scripts/small-team-relay-loopctl.sh status
./scripts/small-team-relay-loopctl.sh logs
./scripts/small-team-relay-loopctl.sh stop
```

`restart` is conservative and only safe with no child, clean tree, correct branch, no in-progress ledger row, and a recoverable prior stop.

Artifacts live outside source control:

```text
~/.pi/small-team-relay-runs/<repo>/run-<timestamp>/
  status.json
  events.log
  tasks/iteration-NNN-<ticket>/
    task.json
    worker-session-N/*.jsonl
    worker-N.md
    pre-red/
    candidate-N.diff
    review-request-N.md
    reviewer-session-N/*.jsonl
    review-final-N.md
    swift-build.log
    matrix.log
    final.diff
    commit.log
```

Control PID/latest-run state:

```text
~/.pi/small-team-relay-loop-control/<repo>/
```

## Supervised gates

### P3.10 — transport/security/deployment decision

Dylan chooses the first relay host, network/TLS route, monthly budget ceiling, workspace privacy default, backup custody, and endpoint trust. Run real-process cross-workspace, revocation, fault, limit, and secret-log evidence. Record decisions without secrets.

### P4.9 — physical iPhone dogfood

Dylan supplies a signed physical iPhone route and optional APNs credentials through protected local storage. Exercise pairing, full transcript, prompts, provider request response, stop, creation, background/foreground, APNs, cache, reconnect, restart, and live revoke.

### P5.7 — final office acceptance

Deploy on selected host; run physical route, external sleep/wake witness, encrypted backup/isolated restore, identity-collision refusal, target soak, security review, and actual Linux build/service proof if advertised. Only after explicit approval may the legacy raw BSD/long-poll/token path be removed.

## Stop conditions

- queue drained;
- supervised ticket first eligible;
- dependencies blocked;
- dirty/wrong-branch/STOP preflight;
- worker/reviewer/provider failure or malformed result;
- out-of-fence edit or worker-created commit;
- review remains `REWORK` after two repair passes;
- focused/build/final matrix failure;
- missing external prerequisite named by packet;
- explicit program STOP.

A stopped dirty run is inspected and recovered directly. Never blindly restart, reset, clean, or launch a second writer.
