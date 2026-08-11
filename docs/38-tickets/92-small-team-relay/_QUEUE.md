# 92-small-team-relay — dependency queue

Exactly 50 tickets. The loop selects the first row whose dependencies are `done` and whose own
state is `pending`. `blocked` is never retried automatically. A `supervised` row stops the loop;
later work may not skip an unresolved infrastructure, physical-device, or release decision.

| # | Ticket | Depends on | Execution |
|---:|---|---|---|
| 1 | `P0.1-program-contract.md` | — | autonomous |
| 2 | `P0.2-relay-protocol-target.md` | P0.1 | autonomous |
| 3 | `P0.3-relay-core-target.md` | P0.2 | autonomous |
| 4 | `P0.4-relay-fixture-corpus.md` | P0.3 | autonomous |
| 5 | `P0.5-legacy-red-baseline.md` | P0.4 | autonomous |
| 6 | `P1.1-sqlite-migration-spine.md` | P0.5 | autonomous |
| 7 | `P1.2-database-open-health.md` | P1.1 | autonomous |
| 8 | `P1.3-event-sequence-transaction.md` | P1.2 | autonomous |
| 9 | `P1.4-persist-before-broadcast-hub.md` | P1.3 | autonomous |
| 10 | `P1.5-snapshot-tail-replay.md` | P1.4 | autonomous |
| 11 | `P1.6-command-receipt-store.md` | P1.5 | autonomous |
| 12 | `P1.7-content-addressed-blob-store.md` | P1.6 | autonomous |
| 13 | `P1.8-quotas-archive-delete.md` | P1.7 | autonomous |
| 14 | `P1.9-online-backup-restore.md` | P1.8 | autonomous |
| 15 | `P1.10-durability-fault-fuzz.md` | P1.9 | autonomous |
| 16 | `P2.1-capability-vocabulary.md` | P1.10 | autonomous |
| 17 | `P2.2-device-credential-registry.md` | P2.1 | autonomous |
| 18 | `P2.3-pairing-grant-state-machine.md` | P2.2 | autonomous |
| 19 | `P2.4-pairing-http-exchange.md` | P2.3 | autonomous |
| 20 | `P2.5-workspace-membership-authorization.md` | P2.4 | autonomous |
| 21 | `P2.6-environment-credential-catalog.md` | P2.5 | autonomous |
| 22 | `P2.7-expiry-revocation-eviction.md` | P2.6 | autonomous |
| 23 | `P2.8-auth-rate-limits-redaction.md` | P2.7 | autonomous |
| 24 | `P2.9-authorization-coverage-fuzz.md` | P2.8 | autonomous |
| 25 | `P3.1-relay-frame-envelope-versioning.md` | P2.9 | autonomous |
| 26 | `P3.2-typed-event-snapshot-frames.md` | P3.1 | autonomous |
| 27 | `P3.3-command-frame-state-machine.md` | P3.2 | autonomous |
| 28 | `P3.4-swift-nio-service-shell.md` | P3.3 | autonomous |
| 29 | `P3.5-bounded-http-routing.md` | P3.4 | autonomous |
| 30 | `P3.6-websocket-auth-subscriptions.md` | P3.5 | autonomous |
| 31 | `P3.7-presence-heartbeat-leases.md` | P3.6 | autonomous |
| 32 | `P3.8-bounded-fanout-backpressure.md` | P3.7 | autonomous |
| 33 | `P3.9-reconnect-cursor-reconciliation.md` | P3.8 | autonomous |
| 34 | `P3.10-transport-security-supervised-review.md` | P3.9 | supervised |
| 35 | `P4.1-execution-host-connector.md` | P3.10 | autonomous |
| 36 | `P4.2-semantic-event-publication.md` | P4.1 | autonomous |
| 37 | `P4.3-client-transcript-reducer-cache.md` | P4.2 | autonomous |
| 38 | `P4.4-prompt-followup-receipts.md` | P4.3 | autonomous |
| 39 | `P4.5-approval-question-responses.md` | P4.4 | autonomous |
| 40 | `P4.6-stop-abort-semantics.md` | P4.5 | autonomous |
| 41 | `P4.7-preconfigured-agent-creation.md` | P4.6 | autonomous |
| 42 | `P4.8-sanitized-apns-projection.md` | P4.7 | autonomous |
| 43 | `P4.9-physical-phone-supervised-dogfood.md` | P4.8 | supervised |
| 44 | `P5.1-relay-configuration-secret-sources.md` | P4.9 | autonomous |
| 45 | `P5.2-health-metrics-redacted-logs.md` | P5.1 | autonomous |
| 46 | `P5.3-admin-cli-device-storage.md` | P5.2 | autonomous |
| 47 | `P5.4-launchd-service-lifecycle.md` | P5.3 | autonomous |
| 48 | `P5.5-linux-systemd-contract.md` | P5.4 | autonomous |
| 49 | `P5.6-capacity-soak-backup-automation.md` | P5.5 | autonomous |
| 50 | `P5.7-final-supervised-office-acceptance.md` | P5.6 | supervised |
