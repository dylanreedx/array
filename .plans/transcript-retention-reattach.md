# Transcript retention: provider history at reattach

Written 2026-11-16 for the two failing cases in `--transcript-retention-check`,
on branch `array/transcript-retention`.

## Who owns what

Three buffers hold an agent's transcript in `AgentSupervisor`.

- `canonicalTranscriptProjections[id]` holds what is saved to disk. It is a
  separate copy once `rehydratedTranscripts[id]` exists or an archive was read
  back. Provider history never enters it.
- `transcriptProjections[id]` is the local display model. It is the only owner
  of the merged history a tile installs at attach, and the shared publisher
  reads it too.
- `rehydratedTranscripts[id]` is the provider (CLI) history, kept for display
  only. It goes into `transcriptProjections` once, as a "previous session"
  notice plus a replay. Base already did this when the projection was created
  after the seed (`transcriptProjection(for:)`).

At attach, the tile installs the `transcriptProjections` snapshot and then
tails live events from `tailBase`, so the snapshot has to be complete.

## Ordering and de-duplication

- Provider history is merged once, at the point where it is seeded. Entries
  from the provider replay get fresh ids (`outside-prompt-<uuid>`, plus the
  ids of the replayed events). Archive and live entries keep their stable ids.
  Nothing is merged twice: the seed is the only merge point, and later
  attaches see it already inside the snapshot (`hasRenderedRehydratedSession`).
- Stream identity is safe because a merge happens only while the projection
  has no live stream to break. Every production seed runs before the agent
  has delivered any runtime event (see below), so the projection holds local
  notices at most.
- The sequence fence for a released transcript is the reload drain. Writes
  queued during a reload are applied in FIFO order. `releasedTranscripts[id]`
  stays set until the queue is empty, and the snapshot is published with no
  suspension in between. Provider history must not be inserted inside that
  window, because no position in it is both "after the archive" and "before
  the queued writes" for a model that has already applied half the queue.

## Case 1: mid-drain provider restore cannot happen in production

There are four production paths into `seedRehydratedTranscript`:

1. Restore wiring (`rehydratePreviousSessionOrNotice`, ContinuumApp). It is
   gated by `needsPreviousSessionNotice`, which requires
   `releasedTranscripts[id] == nil`. It pins with `beginProviderHistoryRead`,
   which refuses a released agent. While that pin is held,
   `transcriptIsDormant` is false, so the agent cannot be released. At
   completion it re-checks `needsPreviousSessionNotice`.
2. Copy (`copyExternalSession`). The agent is spawned and pinned in the same
   main-actor turn. A release needs an asynchronous save, so it cannot happen
   in between, and the pin then holds it.
3. Adoption (`seedAdoptedTranscript` → `finishAdoptingSessionHistory`). This
   path pins with `allowReleased: true`, but its agents carry
   `record.externalSession`, and `transcriptIsDormant` refuses to release any
   linked agent. Every `linkExternalSession` call either targets an agent
   spawned in the same turn (`openExternalSessionTile`) or one that is already
   linked. Released state is in memory only, so a relaunch starts with none.
4. Outside reads (`applyOutsideRead`). The prefix is seeded only when
   `!hasLoadedHistory(id)`, which is false for a released agent and also
   during a drain, because the drain installs `transcriptProjections[id]`
   before it applies the queue.

So a seed never lands while `releasedTranscripts[id] != nil`, and a drain only
runs while it is non-nil. The old witness seeded directly mid-drain, which is
a state production cannot reach. The fix makes that explicit:
`seedRehydratedTranscript` refuses a released agent. The witness is narrowed to
two assertions. First, the production pin refuses a released agent. Second, a
direct mid-drain seed is refused and leaves the archive plus the queued writes
exactly once and in order, in both the saved document and the
attached/reattached tile. Once seeds into released agents are refused, the
reload path's provider-merge branch can no longer run, so it is removed.

## Case 2: status (notice-only) reattachment

Order of events: a restored agent's tile runs `/status`. That creates
`transcriptProjections[id]` holding one local notice. Then the provider read
lands. On base, and on this branch before the fix, the seed only set
`rehydratedTranscripts`. The first tile rendered the history itself. The
supervisor's projection never received it, and a reattached tile marked it as
already drawn (`hasRenderedRehydratedSession`), so it was lost.

The fix: when the projection already exists and every entry in it is a local
notice, the seed appends the notice and replay to it, which matches what the
first tile drew. Order is status → provider → live, the notice keeps its id
and timestamps, and tool details come from the same replay as the
provider-first path. The canonical copy is separated before the merge
(`separateCanonicalTranscriptIfNeeded`), so disk and the companion never see
it. Sharing in the status-first case stays as it was: the supervisor records
the ids of the merged entries, and `sharedTranscriptDocument` removes them.
The provider-first path is unchanged.

If the projection already holds anything other than notices, the old
tile-only behaviour is kept. No production seed reaches that state.

## Save-perf

Interleaved A/B, 5 runs each, base binary at `4c9d7495` against the branch at
`f06a320e`. Worst after-burst frame: base 2.47–2.89 ms, branch 2.50–3.16 ms.
Paced rest-of-frame p95: base 0.13–0.16 ms, branch 0.16–0.22 ms. All 10 runs
pass the 4 ms budget. The earlier 4.4–13.1 ms readings were taken while the
machine was out of memory. No change was made to the save path.
