# Worker 8: COL-14 per-agent context freshness and provenance excerpts

30 October 2026. Bench `.worktrees/mp-w8-freshness`, branch
`array/mp-w8-freshness` off `array/collaboration-finish` (cc168bed).
Commit `d1d8bba5`. Not pushed, not merged.

## What exists now

- `Collaboration.AgentIncarnation` (object plus host generation),
  `ArtifactRevisionRef` and `ResultExcerpt`, in the portable protocol
  (`CollaborationProvenance.swift`).
- `SharedAgentFreshnessLedger`, in Core
  (`Collaboration/SharedAgentContextFreshness.swift`). It is a GRDB file,
  `agent-freshness.sqlite`, mode 0600 inside a 0700 directory. It records
  service `AgentDispatchReceipt`s and computes per-agent freshness against the
  current `SharedArea.Document`.

How the ledger behaves:

- **Baseline.** Only a host-accepted delivery moves an agent's baseline.
  - Queued, claimed or dispatching shows as `awaitingHost`.
  - Refused or uncertain shows as `unresolved` and never advances the baseline.
- **States.** Freshness is `notSent`, `current(rev)`,
  `changedSinceSent(sent, current, newerRevisions)` or
  `agreementRemoved(sent)`. Revision ordinals are 1-based.
  - Label: "Last accepted revision 2 · Current revision 4 · Changed since sent".
  - Fixed caveat: accepted by the host, not read or followed.
- **Immutable input.** The frozen command is written once and keyed by a
  SHA-256 of its canonical JSON. A receipt that carries a different command
  under the same ID is refused (`changedIntent`). Final phases are sticky, so
  a late older receipt cannot move a delivery backwards.
- **Incarnation.** Freshness is keyed by object plus host generation.
  `SharedAgentHostJournal.generation(for:)` mints a new generation when the
  local binding changes, so a rebound agent has no baseline.
  - A runner restart under the same binding keeps its generation. Per-session
    incarnation would need COL-13/15 identity.
- **Excerpts.** Text is frozen, at most 8 KB, with a digest. It names the
  source incarnation, host, turn, sequence, the command it answers and an
  artifact revision. Excerpts cannot be rewritten under the same ID.
  - Availability is `linked`, `sourceRemoved`, `sourceReplaced`,
    `artifactChanged(current)` or `artifactRemoved`. The quote stays readable
    in every case.
- **No sends.** The ledger has no transport, so nothing in it can dispatch.
- **Catch-up.** `unsettledCommands()` lists in-flight commands, so a client can
  re-read every one of them, not only its latest receipt.

## Witness

`SharedAgentFreshnessChecks.swift` runs from the
`ContinuumRevivedCollaborationChecks` main. The `--collaboration` gate and the
full matrix already run that executable, so no new leg or inventory change is
needed.

The setup is a real localhost HTTP service, a real `SharedAgentHostDispatcher`
and journal, and `SharedAgentHandoffController` sends. It makes 21 assertions:

1. Two agents get revision 2 and revision 3 as independent baselines.
2. A queued delivery is not reported as received.
3. Publishing revision 4 marks both agents stale against their own baselines.
   It creates zero dispatches: acceptances are unchanged and the host's pending
   list is empty.
4. The stored command, the service copy and the host journal digest all still
   carry revision 2. A rewrite with revision 4 is refused.
5. A refused resend does not advance the baseline.
6. A client, ledger and host relaunch reproduces identical state and
   dispatches nothing.
7. A ledger rebuilt from service receipts matches the original. A third member
   gets 403.
8. A rebind starts with no baseline.
9. Excerpt provenance and availability, removed agents and a removed agreement
   are each labelled honestly.

Teeth, each run RED and then restored:

- Refused or uncertain receipts advance the baseline → RED at "refused
  delivery … does not advance the baseline".
- The frozen-command digest guard is removed → RED at "receipt that would
  rewrite an accepted command … is refused".
- The baseline is keyed by object only → RED at "replaced binding starts with
  no baseline".

Runs on this bench:

- `ContinuumRevivedCollaborationChecks`: exit 0, 21 freshness PASS lines.
- `ContinuumRevivedCollaborationServiceChecks`: exit 0, after building
  `continuum-relay`.

Not run: `scripts/run-matrix.sh --collaboration`. It starts with an App build,
and three other Array builds were running, so the
`--collaboration-native-check`, `--ui-probe-check` and `--menu-contract-check`
legs were not exercised here. This change touches no App target code. Linux
container: not run. The protocol file uses only Foundation and Crypto.

## Lead-owned hunks (not applied)

The production client should feed the ledger. The hunk below goes in
`SharedAgentHandoffController.swift`:

```swift
// stored property
public let freshness: SharedAgentFreshnessLedger
// init, after `intents = ...`
freshness = try .init(directory: directory.appendingPathComponent("freshness", isDirectory: true))
// refresh(object:), after the existing receipt refresh
for id in try freshness.unsettledCommands() { try freshness.record(try await transport.receipt(id: id)) }
// deliver(_:), case .prompt, after `receipt = try await transport.send(...)`
try freshness.record(receipt!)
```

The registration line in `ContinuumRevivedCollaborationChecks/main.swift` is
already committed here.

## Open decisions and gaps

- **Teammate visibility.** The service shows a receipt only to its requester
  and the agent's owner. Other members cannot see per-agent freshness, which
  is why `notSent` reads "on this device".
  - Showing everyone the same state needs a service projection: revision ID,
    phase and incarnation, without prompt text. That is a product and privacy
    call for the lead.
- **Excerpts in discussion.** `SharedArea.Post` cannot reference an excerpt
  yet. That needs an additive protocol field, owned by the lead or COL-12, plus
  an export rule.
- **Shapes from worker 7.** Turn and sequence shapes are provisional
  (`turn: String`, `sequence: UInt64?`). They should match whatever worker 7's
  live projection publishes.
- **Shapes from worker 6.** Aligned: `ArtifactRevisionRef.revision` is the UUID of
  `Artifact.Manifest.id` and `contentDigest` matches (w6 1f5687d6). Drift
  (`sourceChanged`) stays on w6's `Applicability`; excerpts report only a moved
  latest revision or a removed artifact.
- **UI.** No native UI renders freshness or excerpts yet.
