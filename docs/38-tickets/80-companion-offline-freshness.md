# Companion offline/freshness model — cached canvas without lying

Status: **done / landed at `e8c6841`, 2026-07-06.** Second implementation ticket for `_PAIR_TO_INSTANCE_PLAN.md`. This now unlocks the rewritten ticket 75 publisher path.

## Product problem

The Mac will be asleep, offline, quitting, waking, or delayed through CloudKit. The iPhone should not feel broken when that happens.

Desired MVP behavior:

- If cached canvas/agent data exists, keep showing it.
- Make freshness impossible to miss: `Live`, `Syncing…`, `Stale as of 8:14`, `Mac asleep/offline — showing last canvas`.
- Do not pretend stale data is live.
- Do not blank the canvas just because the desktop is temporarily unreachable.
- Do not queue dangerous actions offline in v1.

Dylan's phrase “canvas asleep” is good product copy, but protocol truth should be more precise: the phone either received an explicit sleep/shutdown hint or inferred staleness from missing heartbeats/snapshots.

## Outcome

After this ticket:

- Shared Core/Sync model derives companion freshness from timestamps, watermarks, power hints, and transport/account state.
- Desktop publisher paths have a metadata contract for heartbeat/snapshot freshness, even if ticket 75 wires the actual publisher later.
- iOS uses the model to show cached state honestly.
- Mutating controls are disabled while stale/offline unless a live session is available.
- Checks prove the state machine without depending on real CloudKit, wall-clock sleeps, or a physical phone.

## Scope

### In scope

1. **Shared freshness model**
   - Add a pure model such as `CompanionFreshness`, `CompanionFreshnessInput`, and `CompanionFreshnessPolicy` in a shared SwiftPM target.
   - Inputs should include:
     - paired/unpaired session state;
     - latest spatial snapshot publishedAt/receivedAt;
     - latest activity snapshot publishedAt/receivedAt;
     - latest heartbeat publishedAt/receivedAt;
     - last transport connection state / account availability;
     - optional desktop power hint: `active`, `willSleep`, `waking`, `shuttingDown`, `unknown`;
     - local `now` injected for testability.
   - Outputs should include:
     - `syncing`;
     - `live`;
     - `stale(lastFreshAt)`;
     - `desktopSleeping(lastFreshAt)`;
     - `offline(lastFreshAt, reason)`;
     - `unpaired`;
     - user-facing title/subtitle tokens;
     - whether mutations are allowed.

2. **Freshness metadata contract**
   - Define a transport-agnostic envelope/header or sidecar model for companion-published data:
     - `instanceId`;
     - `desktopReplicaId` / publisher id;
     - `bootId` or launch id;
     - sequence/watermark;
     - `publishedAt`;
     - `powerHint`;
     - spatial/activity watermarks where applicable.
   - Ticket 75's publisher must later attach this metadata to spatial/activity snapshots and heartbeats.
   - This ticket may add the type and fake-transport tests without rewiring all CloudKit records yet.

3. **iOS cached-state UX contract**
   - iOS state/view model should distinguish:
     - no paired session;
     - paired but no data yet;
     - paired with cached data but stale/offline;
     - live.
   - Screens should keep rendering cached canvas/agent state when stale.
   - Banner/footer copy should use the freshness model output, not ad hoc CloudKit strings.
   - If no cached data exists, show `Waiting for your Mac` / `No canvas synced yet` instead of an empty workspace that looks real.

4. **Action gating while stale**
   - Disable canvas edits, approve/deny, and terminal-operating actions when freshness is not live.
   - MVP rule: no offline mutation queue.
   - UI copy should say `Reconnect to act` or `Mac offline/asleep` rather than `observer scope` when the blocker is freshness.
   - Scope gate still applies after freshness gate; do not weaken scope checks.

5. **Best-effort desktop lifecycle hints**
   - Add model hooks or service seam for future desktop publisher to emit:
     - periodic heartbeat;
     - `willSleep`;
     - `waking`;
     - `shuttingDown`.
   - If app-layer code is touched, use macOS notifications behind an injectable seam so checks do not require real sleep/wake.
   - It is acceptable for the actual CloudKit publication of these hints to remain ticket-75 work, as long as the contract is explicit and checked.

6. **Checks**
   - Pure table checks for the freshness derivation:
     - unpaired;
     - paired/no data → syncing;
     - recent heartbeat → live;
     - old heartbeat + cached canvas → stale;
     - explicit `willSleep` + cached canvas → desktopSleeping;
     - account/network unavailable → offline;
     - delivery lag is diagnosable separately from desktop silence.
   - UI/view-model checks proving:
     - cached canvas remains visible while stale/offline;
     - no-data state does not masquerade as empty canvas;
     - mutations disabled when stale/offline and enabled only when freshness live + scope permits.
   - Fake transport/check fixture proving stale transition does not require real CloudKit or wall-clock sleeps.

### Out of scope

- Pairing/auth storage itself; ticket 79.
- Desktop CloudKit publisher rewrite; ticket 75 rewrite.
- APNs offline notifications beyond using the taxonomy later.
- Waking the Mac remotely.
- Background refresh guarantees on iOS.
- Offline mutation queues or conflict-resolution UI.
- Perfectly detecting sleep. We infer when hints are absent.

## Suggested state thresholds

Initial constants, tune later:

- live window: heartbeat/snapshot < 90 seconds old;
- stale window: 90 seconds–5 minutes;
- sleeping/offline copy: > 5 minutes or explicit `willSleep` / `shuttingDown` hint;
- no hard expiration for cached canvas display; only the action controls expire.

The exact numbers should live in `CompanionFreshnessPolicy`, not hard-coded throughout views.

## UX copy defaults

| derived state | title | subtitle | mutations |
| --- | --- | --- | --- |
| unpaired | `Pair this phone` | `Connect to your Continuum instance` | disabled |
| syncing | `Syncing…` | `Waiting for your Mac` | disabled |
| live | `Live` | `Updated just now` | scope-gated |
| stale | `Stale` | `Showing last canvas from 8:14 AM` | disabled |
| desktopSleeping | `Mac asleep` | `Canvas asleep — showing 8:14 AM` | disabled |
| offline | `Offline` | `Mac offline/asleep — showing 8:14 AM` | disabled |

Use diagnostics/logs for exact reasons; keep product copy calm.

## Files likely touched

- Shared model in `Sources/ContinuumRevivedCore` or `Sources/ContinuumRevivedSync`.
- iOS app view model/state files under `ios/Continuum/Sources/`.
- Existing iOS Canvas/Agents/Approvals freshness labels and action gating.
- `Sources/ContinuumRevivedCoreChecks` and/or `Sources/ContinuumRevivedSyncChecks`.
- Possibly a tiny app-layer lifecycle seam for future desktop heartbeat publisher.

## Verification

Required gates:

```bash
swift build
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
cd ios && xcodegen generate && xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination 'generic/platform=iOS Simulator' build
```

The iOS build gate is required because the ticket changes iOS UX/model wiring.

## Done when

- Freshness is a shared pure model with threshold policy and injected `now`.
- iOS renders paired/no-data/live/stale/sleeping/offline distinctly.
- Cached canvas/agent state remains visible when stale/offline.
- Mutating controls are disabled while stale/offline and never queued.
- Desktop publisher follow-up has an explicit heartbeat/power-hint metadata contract.
- Matrix and iOS simulator build are green.

## Watch out for

- Do not claim the Mac is definitely asleep unless an explicit hint exists; otherwise say asleep/offline or likely asleep.
- Do not hide stale data by rendering a blank canvas.
- Do not allow approve/deny from stale snapshots.
- Do not duplicate freshness logic separately in Agents/Canvas/Approvals.
- Do not weaken scope authorization; freshness gating is an additional gate.
