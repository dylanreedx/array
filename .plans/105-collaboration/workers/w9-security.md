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
