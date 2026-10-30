# MP worker 9 — COL-20 boundary audit

30 October 2026. Bench `.worktrees/mp-w9-security`, branch `array/mp-w9-security`,
from `array/collaboration-finish` at `cc168bed`.

## What was built

Two offline adversarial witnesses, both inside legs the `--collaboration` gate
already runs, so the matrix inventory is unchanged.

1. `Sources/ContinuumRevivedCollaborationServiceChecks/CollaborationBoundaryAuditChecks.swift`
   runs in the default service-checks leg, and alone with `--boundary-audit-only`.
   It uses real localhost routes and four principals: A (owner), B (editor),
   V (viewer) and C (excluded from area X, owner of area Y).
   - **Counterexample first.** The same probes from entitled principals do
     return the post, agreement, history, presence label, usage total and
     prompt sentinels, so the probe can see a leak.
   - **Excluded C, guessed IDs.** 22 nested routes: state, updates, presence,
     invitations, commands, member removal, usage, agent hosts, control,
     prompts, the host queue, receipts, claim, admit and outcome. They also
     cover the not-yet-existing artifact, blob and history paths. A real ID
     gives byte-identical status and body to a random one, and the response
     carries no sentinel. A before/after fingerprint shows no effect: the
     document, the queued dispatch, the control state, presence and the epoch.
   - **Member B, forwarded pointers across two areas it belongs to.** It tries:
     - X's object in Y;
     - Y's agreement revision in X;
     - X's dispatch and control via Y's path;
     - A's host in Y;
     - a recipient claiming the host's work.

     All are refused, carry no protected bytes, and leave both areas unchanged.
   - **Viewer V** cannot read B's prompt, prompt the agent or poll A's host queue.
   - **Revocation with stale queued work.** The host caches a pending list, then
     goes offline, and B is removed. B now reads X exactly like an unknown area.
     The host's cached claim or admit is refused with no phase change. B is
     re-admitted:
     - its replay returns the inert old receipt, which still cannot be admitted;
     - the old control grant is dead.

     The host reconnects and re-registers; the stale prompt resolves `refused`,
     and an old-epoch control mutation cannot take control back.
   - **Device revocation after claim.** Admission is refused, and an
     enrollment code minted by the revoked device is dead (410). The revoked
     bearer reads nothing (401). After the host reports `refused`, a
     contradictory `accepted` cannot rewrite it.
   - **Partial and failure outcomes:**
     - a batch with one forged edit commits none of its allowed edits;
     - a removal that fails at the epoch bump leaves membership and the epoch
       untouched;
     - a prompt whose insert fails leaves no receipt and echoes no text, then
       succeeds once on retry.
   - **Storage.** The SQLite database, WAL and SHM files contain no plaintext
     posts, agreements, prompts, tokens, invitation codes or enrollment codes.
   - **Logs.** The real `continuum-relay` process is run in its own temp dir
     with real traffic: success, a forged author, a bad bearer carrying content,
     malformed JSON carrying content, an oversized body and a replayed code,
     then SIGINT. Its stdout and stderr contain the `ready` and `stopped` lines
     (positive control). They contain no content, labels, area or person IDs,
     tokens, codes or keys.
2. `Sources/ContinuumRevivedCollaborationChecks/SharedAgentRevocationRaceChecks.swift`
   drives the production `SharedAgentHostDispatcher` over real HTTP. A one-shot
   transport hook lands each revocation exactly between dispatcher calls.
   - Positive control: the same dispatcher executes an authorized prompt once.
   - R1: B is removed and re-admitted while the host is offline. The reconnect
     refuses the stale prompt and returns control to A.
   - R2: B is removed after the pending poll, before the claim. Nothing is
     claimed or executed, and after re-admission the prompt resolves `refused`.
   - R3: B's device is revoked after the claim, before admission. Nothing
     executes; the journal holds exactly one accepted attempt, and the revoked
     bearer cannot read its receipt.

## Teeth

Each mutation was applied to production and both affected binaries were
rebuilt. Each run went RED on the intended assertion, then the file was
restored and the run was GREEN again.

| Mutation | RED assertion |
| --- | --- |
| `agentDispatchReceipt` skips the membership scope | excluded C distinguishes `GET …/agent-commands/<id>` (403 vs 404) |
| `claimAgentDispatch` skips `validateDispatchAuthority` | service: cached host claim; race: removal between poll and claim |
| route writes the bearer token to stderr | relay log carries a protected value |
| `redeem` ignores a revoked issuing device | revoked device's enrollment code is dead |
| `.post` authorship unchecked | forged-edit batch commits nothing |

A first T3 run looked GREEN because the relay subprocess binary had not been
rebuilt. That is the stale-binary hazard; the repeated run rebuilt both binaries.

## Findings routed

1. **Lead (Core, `SharedAgentHandoffTransport.swift`, `dispatch`).** When admission
   gets a definitive 403 after the irreversible attempt marker, the host reports
   the prompt as `uncertain`. Yet `execute` was never called, because the marker
   precedes the admit call and the admit threw. The requester sees "may have
   run" for a prompt that provably did not. Suggested fix: if `transport.admit`
   throws a server refusal (403/404/409) before `execute`, finish the journal and
   the receipt as `refused`. Keep `uncertain` for transport errors and lost
   responses. R3 now asserts only "final, not accepted, no execution"; tighten
   it to `.refused` with the fix.
2. **Lead (policy, COL-19 retention).** `.remove` keeps an object's posts and
   agreement text in the snapshot and the replayable operation log. A person
   invited after an unpublish therefore still receives the removed content.
   That matches the recorded "all retained history on join" decision. COL-19
   should decide whether unpublish needs a history floor for late joiners.
3. **Lead (low).** A removed requester's queued command answers the host's
   claim and admit with 404 (the requester's scope is missing), where other
   authority failures give 403. Both refuse and change nothing; the host just
   cannot tell "dispatch gone" from "requester gone". The audit accepts either.
4. **Lead (low).** A same-area member gets 403 for a real dispatch ID and 404 for
   a random one, an existence oracle. Dispatch IDs are client UUIDs that are
   never shown to other members, so this is negligible. Excluded members see
   no difference (witnessed).

No finding for the artifact or live-views workers: their surfaces don't exist
on this base.

## Not covered, and why

- **Artifact blobs and previews (COL-16)** and **retention/compaction (COL-19)**:
  no routes on this base. The excluded-principal sweep already probes
  `artifacts/<id>`, `artifacts/<id>/blob` and `history`, so once those routes
  land, a real area that answers differently from a random one goes RED. Their
  member-level byte, digest and revocation cases are still owed when they land.
- **Transcript snapshot and tail bytes (COL-15)**: not published yet;
  observations carry identity and layout only.
- **The app's durable `.queue` drain after revocation** (`SharedAreaHostSession`):
  this needs an app build. The service half is witnessed: admitting an
  accepted queue-mode command re-validates authority.

## Verification

- `ContinuumRevivedCollaborationServiceChecks` (default mode): exit 0, with 28
  boundary-audit PASS lines.
- `ContinuumRevivedCollaborationChecks`: exit 0, with the revocation-race section.
- `continuum-relay` was rebuilt before every log run.
- Not run: the full matrix, the Linux container, the Array app build, any
  default tmux socket or production relay.

## Round 2: artifacts, retention and backups (30 October 2026)

The bench was rebased onto `array/collaboration-finish` at `e17d0a52`, which now
has artifacts (COL-16) and compaction/retention (COL-19). The first round's
commit was already merged there.

### New witness

`CollaborationBoundaryAuditArtifactChecks.swift` runs inside the same default
service-checks leg (and `--boundary-audit-only`). It uses real NIO routes, and
its store compacts after every command (tail 2, batch 1, age 0). An injectable
clock drives the 15-minute dispatch authority window.

- **Counterexample.** A member receives the blob bytes, with
  `cache-control: no-store`, plus the manifest path and the review note.
- **Excluded C.** On 8 artifact and history routes, a real ID gives byte-identical
  output to a random one, and nothing changes. The routes are state, revision,
  blob, upload, publish, review, drift and updates.
- **Member B forwarding pointers.** Each of these reads exactly like an unknown
  blob:
  - a blob path under area Y;
  - another object's revision;
  - an uploaded draft blob that no manifest lists;
  - a cross-object revision;
  - a discussion ID used as an artifact.

  B cannot upload to or publish A's artifact, V cannot review, and nothing
  changes.
- **Unpublish.** Before and after: the member's cached blob URL and the
  artifact state then read like an unknown object, even for the owner.
- **Pinned policy.** Late joiner D receives a removed discussion's text, but
  never an unpublished artifact's bytes.
- **Retention.**
  - After compaction, the store's integrity verification passes.
  - Behind the horizon, excluded C gets the unknown-area 404, never a
    "snapshot required" that would reveal the area.
  - Member B gets a content-free 409.
  - Removed B's horizon read and cached blob URL equal an unknown area's.
  - A compacted operation ID cannot be reused or exactly replayed by another
    person, nor changed by its re-admitted author.
- **Stale queued work.** A prompt queued before compaction, removal and
  re-admission cannot be claimed or admitted. Past the authority window, a
  still-authorized prompt is refused at claim and nothing stays pending.
- **Storage.** After compaction, the database, WAL and SHM keep blobs, the
  unlisted draft, paths, reviews and the horizon snapshot sealed.

The relay process log audit now also drives artifact traffic: upload, publish,
member fetch, a hash mismatch, an oversized blob and a forbidden upload. It
then runs the operator `--collaboration-backup`, `--collaboration-verify-backup`
and a failing verify as subprocesses. Positive control: each one succeeds or
fails as expected and logs its event. Their output carries no content, IDs,
tokens, codes or keys, and the backup file keeps them sealed.

### Teeth, round 2

Each mutation was applied with both the service-checks and `continuum-relay`
binaries rebuilt. Each went RED on the intended assertion, then the file was
restored and the run was GREEN again.

| Mutation | RED assertion |
| --- | --- |
| `artifactBlob` skips current membership | excluded C distinguishes the blob route |
| `artifactBlob` serves any stored digest of the object | member B reads the unlisted draft |
| horizon checked before membership | excluded C sees "snapshot required" |
| authority window never expires | stale prompt still pending past the window |
| operation-ID binding read from the compactable log | A's exact replay of B's retired command |
| artifact route writes its URI to stderr | relay log carries a protected value |
| unpublished artifact stays readable | cached blob after unpublish |

The operation-ID mutation was GREEN at first. My changed-content probes are
refused by the document's own receipt digest anyway, so they could not see the
binding move. The binding only matters for an exact replay by another person,
which would otherwise get that person's receipt back. That probe was added, and
the mutation now goes RED. A first draft-blob mutation was too crude: it broke
the legitimate read as well. The precise version, which skips only the manifest
listing, goes RED on the forwarded-pointer step.

Two fixture traps, fixed:
- A path sentinel containing `/` can never match JSON output, because the
  encoder writes `\/`. That would have hidden a real path leak, so the sentinel
  now has no slash.
- The publish probe's body named the real object while the URL named a random
  one. The service checks body against URL before authenticating, so the 400
  reflected the caller's own input, not server state. Each body now names its
  own URL's object.

### Review items

- **Logs.** The relay and operator commands log only event names, ports,
  counts and command names. A failure logs the error's description, and the
  audit drives that path. No content or credentials appear (witnessed above).
- **Storage, keys and retention.** These match the trusted-service contract.
  AES-GCM seals snapshots, operations, horizon snapshots, artifact records,
  reviews and blobs, with blob AAD binding area, object and digest. Tokens and
  codes are SHA-256 hashes. Backups copy ciphertext and never the key.
  Two docs statements were stale, and both are corrected:
  - "the service stores references, never artifact bytes";
  - "blob storage remains future work".

  The retention table now also states that unpublished artifact bytes stay
  sealed but unreachable for the life of the area.
- **E2EE claims.** None in product copy. Searching the app's collaboration UI,
  canvas, Core collaboration and the website finds only two unrelated code
  comments. The internals doc says "This is not group E2EE." This is a source
  search, not a witness.

### Policy items (lead decisions)

- **Item 2.** "All retained history on join" stays. The tradeoff is written into
  `docs/internals/collaboration.md` ("History on join, a decision for Dylan")
  and pinned by the witness above.
- **Items 3 and 4.** The 404/403 behaviour stays. It is documented under the
  HTTP contract.
- **Finding 1.** Worker 4 is fixing it on `array/col-admission`. R3 still asserts
  only "final, not accepted, no execution", and tightens to `.refused` with that
  fix.

### Linux relay leg: memory, found and fixed (`ci(relay)` commit)

The first round-2 gate was GREEN on every Mac leg; the audit printed all 57 of
its PASS lines. Only the new Linux relay leg failed. Swift 6.1 compiles the
checks module in a whole-module release build, which runs one LLVM codegen
thread per CPU. The Docker VM has 15 CPUs under amd64 emulation, and the
compiler was killed (signal 9, "cannot allocate memory").

Measured in a container built from the same image, by sampling the compiler's
`VmHWM` (its peak resident memory):

| Variant | Codegen threads | Compiler peak | Result |
| --- | --- | --- | --- |
| Base, before this round (`5fa07c36`) | 15 | 7.1 GB | passes, with about 8% headroom in a 7.75 GB VM |
| My artifact audit emptied | 15 | 7.3 GB | passes |
| This round, complete | 15 | killed | out of memory |
| My functions marked `@_optimize(none)` | 15 | killed | not the optimizer |
| `swift build -j 2` | 15 | killed | `-j` does not reach codegen threads |
| `-Xswiftc -num-threads -Xswiftc 4` | 4 | 5.9 GB | passes, little margin |
| `-Xswiftc -num-threads -Xswiftc 2` | 2 | 3.7 GB | passes |

So the module was one addition away from this failure before my round; any
worker's next file would have tipped it. The fix caps the checks-stage build of
`ContinuumRevivedCollaborationServiceChecks` at two codegen threads. The shipped
relay build stage is unchanged. With the cap, `scripts/check-relay-linux.sh`
passed: the audit's 57 PASS lines ran twice, once in the image build and once
in the separate `docker run`. The Dockerfile is not mine. The change is its own
commit, so the integrator can take or replace it.

### Commits on `array/mp-w9-security`

- `test(collaboration): audit artifact, retention and backup boundaries`
- `docs(collaboration): record history-on-join and refusal status decisions`
- `ci(relay): cap codegen threads for the Linux collaboration checks build`
- `test(collaboration): discard createFile results in the relay log audit`

### Final gate (rebased on `4969619a`)

`scripts/run-matrix.sh --collaboration`, run under the build lock: 11 legs ran.
Every Mac leg passed, including the boundary audit (57 PASS lines) and the
revocation race (8 PASS lines). The Linux relay leg failed before it reached
any checks. `continuum-relay` itself no longer compiles on Swift 6.1:
`CollaborationUpdates.swift:112: error: sending 'db' risks causing data races`.
This comes from `d41d3fab` (host heartbeats), which also fails the
coordinator's own gate at `cfab6252`. It is not caused by this branch.
With the memory cap, the Linux leg passed on the pre-heartbeat base.
