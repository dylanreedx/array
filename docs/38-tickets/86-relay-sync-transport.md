# Relay sync transport — self-owned op relay behind the SyncTransport seam

**Phase 6 — Sync & multi-device · ticket 86 · authorizes D4-R1 (see 38-locked-decisions.md)**

## Why (decision context)

D4-R1 (2026-07-18): the relay upgrade path documented in D4 is promoted to the active
transport. Dylan's requirements, verbatim intent: device sync must NOT require iCloud
sign-in on any device, and the transport must be fully remote — "LAN defeats the whole
purpose of remote agent orchestration." Both requirements point at the same shape:
Mac and phone each dial OUT over the internet to a relay we own; the pairing-token +
`Scope` model (already built, account-less) authorizes both legs.

CloudKit (`CloudKitSyncTransport`) is parked behind the seam — code and checks stay,
no further investment. The demux/receiver/publisher stack is transport-agnostic and
carries over unchanged. I5 (geometry/projection fields only; no runtimeRef/pids/paths/
secrets) is transport-independent and applies verbatim; the relay hub must wire the
same `SyncPayloadTaint` primitive into its delivery path that `FakeSyncTransport` does.

## Target shape

```
Mac app ──publish──▶ ┌───────────────┐ ◀──subscribe── iPhone app
 (operator token)    │   RelayHub    │   (observer token)
                     │ seq-ordered   │
                     │ ring buffer + │
                     │ latest        │
                     │ snapshot      │
                     └───────────────┘
   dev: in-process / localhost        prod: VPS behind TLS
```

- **One ordered stream.** Envelopes carry a monotonically increasing `seq` assigned by
  the hub. Subscribers hold a cursor (last applied `seq`).
- **Catch-up.** Reconnect sends the cursor: hub replays the ring tail after it. Cursor
  older than the ring start (or nil) → latest `CompactedSnapshot` first, then the tail
  after that snapshot's seq. Loro/op-log idempotency means duplicates are harmless;
  the hub does NOT dedupe (same doctrine as `FakeSyncTransport`).
- **Auth.** `ClientHello` carries the pairing bearer token; a `TokenValidator`
  injection point maps token → `Scope`. Observer scope may subscribe only; publish
  requires the operator/desktop scope. The hub never sees Apple identity of any kind.
- **Taint.** Every envelope's encoded JSON passes `SyncPayloadTaint.violations` before
  it enters the ring; violations are refused, not delivered.

## Slices

1. **RelayHub core + wire format + checks (this repo, no sockets).**
   `RelayWire.swift` (versioned Codable frames: `ClientHello`, `ServerWelcome`,
   `Envelope(seq:message:)`, `ErrorFrame`), `RelayHub.swift` (actor: sessions, scope
   enforcement, ring buffer + latest-snapshot compaction, cursor catch-up, taint gate),
   `ContinuumRevivedRelayChecks` executable wired into `run-matrix.sh`. All correctness
   proofs in-process, forever — sockets are an adapter, never the test substrate.
2. **Localhost adapters + app wiring.** Server: HTTP long-poll on the raw-BSD-socket
   listener pattern `LocalPairingEndpoint` already proves (`POST /relay/publish`,
   `GET /relay/poll?cursor=N` with bounded wait) — WebSocket is an optional upgrade,
   not a requirement; long-poll keeps the protocol portable and the client trivial
   (`URLSession` both platforms, zero new dependencies). Client:
   `RelaySyncTransport: SyncTransport` delegating to the same demux/receivers.
   App wiring: transport selection (relay URL; `CloudKitSyncTransport` only as
   explicit fallback), iOS `start()` drops the `CKAccountStatus` gate in relay mode
   (the gate becomes hello/welcome success), sim loop runs with ZERO Apple accounts.
3. **VPS deploy.** The hub process on the §1 VPS behind TLS (caddy/nginx terminating),
   pairing-token validation via the same `CompanionAuthService` store the Mac exports
   to it, ops runbook + health checks. Linux portability of the slice-2 server is a
   known cost (BSD-socket listener is Darwin-flavored; port or front it) — decided in
   this slice, not before.
4. **Retire-or-keep CloudKit + push.** After the relay is the proven daily path:
   decide whether CloudKit code is deleted or kept as fallback; APNS wake-on-event
   (D7) integrates with the relay's publish hook.

## Checks (slice 1, RED→GREEN)

- bad/unknown token → hello refused; no session.
- observer token: subscribe ok, publish refused (`Scope` is the type-level guarantee).
- publisher → N subscribers: fan-out preserves hub order; seq strictly monotonic.
- fresh subscriber (nil cursor): latest snapshot then tail, no gaps.
- cursor mid-ring: exactly the tail after cursor — no duplicates, no gaps.
- cursor evicted (older than ring start): snapshot + full ring — lossless catch-up.
- duplicate publish of the same `LoggedOp` delivered twice (hub must NOT dedupe).
- adversarial pre-encoded taint frame refused via `SyncPayloadTaint` (same primitive,
  same doctrine as `FakeSyncTransport`).

Manifest doctrine as everywhere: measured values + "via" tags; the checks executable
joins `scripts/run-matrix.sh` and the matrix must stay green (`CONTINUUM_SKIP_SURFACE_CHECKS=1`
honest-green rule unchanged).

## Explicitly out of scope

- Multi-user / multi-workspace routing (single-owner hub; one topic space).
- Server-side op validation beyond taint + scope (materialize stays client-side).
- E2E payload encryption (owner's own VPS; revisit before any multi-tenant future).
- Deleting CloudKit code (slice 4 decision).
