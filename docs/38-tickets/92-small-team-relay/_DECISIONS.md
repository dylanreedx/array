# 92-small-team-relay — decision record

This file records owner-approved implementation decisions without secrets. `_DESIGN.md` is locked unless a decision here explicitly supersedes a numbered rule.

## Recorded

| ID | Decision | Status | Notes |
|---|---|---|---|
| R1 | Build one trusted small-team relay, not a public T3 Connect clone. | approved | Target ~10 teammates / 30 devices / 20 environments / 100 agents / 100 sockets. |
| R2 | Budget for approximately $5/month or less when useful, but record actual cost honestly. | approved | Existing hardware may be cheaper; no permanent vendor-price promise. |
| R3 | Execution hosts retain provider credentials, environment values, process/filesystem authority, and final command rejection. | approved | Relay is trusted routing/mirror authority, not generic remote execution. |
| R4 | Use SQLite WAL plus relay-owned content-addressed blobs. | approved | No Redis/Kafka/PlanetScale/object store in v1. |
| R5 | Persist events before broadcast and use `(generation, sequence)` replay. | approved | Snapshot+tail is a performance/recovery mechanism. |
| R6 | Commands use `(deviceID,idempotencyKey)` and honest `indeterminate` state. | approved | No exactly-once provider claim or blind ambiguous redispatch. |
| R7 | Use typed privileged RelayFrame protocol, separate from generic SyncMessage. | approved | Native non-executable rendering only. |
| R8 | Replace blanket I5 with Class A sanitized push, Class B authenticated interactive content, and Class C host-only secrets. | approved | Approved by starting the companion catch-up plan on 2026-08-10; P0 still owes the corresponding repository decision and structural checks before P3.2 ships. |
| R9 | Pair through server-generated one-use secrets and hashed revocable opaque credentials. | approved | Client-supplied scope bits are forbidden. |
| R10 | Private-network/loopback first; public bind requires supervised owner approval. | approved | TLS/private routing choice remains pending. |
| R11 | Direct APNs is optional and carries Class A only. | approved | `.p8` stays in protected relay secret storage. |
| R12 | Actual system sleep suspends local execution; another awake host is required for continuity. | approved | Idle-sleep assertion policy pending. |

## Pending owner decisions

| ID | Decision needed | Due | Options / recording requirement |
|---|---|---|---|
| O1 | First relay host | P3.10 | Existing office host vs approved low-cost VPS; record actual provider/region/spec/cost/date if hosted. |
| O2 | First network/TLS route | P3.10 | Existing VPN/WireGuard, licensed private mesh, LAN milestone, or public TLS. |
| O3 | Workspace privacy default | P3.10 | Private/invite-only recommended vs office-wide shared. |
| O4 | Backup destination/retention/custodian | P3.10 | Must be encrypted and off relay machine. |
| O5 | Recovery-key custody and authorized recoverers | P3.10 | Record location class/owners, never key material. |
| O6 | Public TLS provider visibility of Class-B data | P3.10 if public | Explicit accept/reject. |
| O7 | iPhone revoke/cache policy | P4.9 | Immediate erase vs bounded encrypted read-only retention. |
| O8 | Lock-screen notification privacy | P4.9 | Whether agent/workspace names are allowed. |
| O9 | Active-turn idle-sleep assertion | P5.7 | Plugged-in default, per-machine opt-in, or never. |
| O10 | Final monthly ceiling and operations owner | P5.7 | Record measured recurring cost and named maintenance owner. |

## Supersession procedure

A new decision must state:

1. which rule/decision it supersedes;
2. why current evidence requires the change;
3. affected tickets/files/tests/migrations;
4. security/privacy/recovery consequences;
5. owner approval date.

Workers do not author or approve superseding decisions. They block with evidence.
