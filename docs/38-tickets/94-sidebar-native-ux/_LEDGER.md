# 94-sidebar-native-ux — execution ledger

## heartbeat

last-touch 2026-08-04T01:41:55Z · ticket P3.1-launch-reconciliation-sweep.md · attempt 1 · pid — · status done

## states

`pending` · `in-progress` · `done` · `blocked`

| Ticket | State | Commit | Updated | Note |
|---|---|---|---|---|
| `P0.1-program-contract.md` | done | this commit | 2026-08-03T22:15:24Z | Harness-owned completion: focused worker checks, independent opposite-model review, swift build, and final matrix passed. Evidence: /Users/dylan/.pi/sidebar-native-ux-runs/continuum-overnight/run-20260803T170016/tasks/iteration-001-P0.1-program-contract.md. |
| `P0.2-sidebar-check-seam.md` | done | this commit | 2026-08-03T23:11:58Z | Focus-session completion (loop retired; see plan-focus-session-handoff.md): worker's probe + QA seam preserved from the blocked loop run, matrix leg and inventory record added here. --sidebar-ux-check green at 220/280/320 in both appearances: 42 cells, 252 labels, 24 eliding by drawable width, zero-size host refused. |
| `P0.3-row-fixture-corpus.md` | done | this commit | 2026-08-04T01:03:10Z | Focus-session completion: 11 declared shapes / 53 corpus rows with two-way declaration-usage parity, coverage pinned (5 states, 3 attention, 4 lifecycles, 2 variants, depths 0-2), 40-child fan-out, 100h elapsed, bidi+combining title. Probe re-pointed at the corpus with content-derived host height (fence deviation: UIProbeGeometry.swift, the probe renders the corpus). AgentUIChecks + sidebar-ux-check (318 cells/1884 labels/208 eliding) + component-lab (60 baselines byte-identical) + agent-inbox-check all green. Negative witnesses observed red then restored green: planted /Users home path (exit 1, I5 hygiene), planted ssh-rsa key shape (exit 1, I5 hygiene), .failed coverage removed (exit 1, coverage). |
| `P0.4-inbox-geometry-gate.md` | done | this commit | 2026-08-04T01:41:55Z | Focus-session completion: checkSidebarTruncationGate in --ui-geometry-check measures 1302 labels at WorkspaceSidebarConfig min/default + wide in both appearances, truncation by drawable width vs needed (+4pt inset). ENTRY WITNESS: empty table went red naming 117 truncations, almost all titles at min/default (the yields-first defect) — e.g. row0.title@min lost 124.5pt, row48.title lost 110pt at every width behind its oversized project chip. Those 117 keys are now expectedSidebarTruncations; new truncation red AND healed-but-tracked red, so P2.1/P2.2 must shrink it. Source scan forbids width digit literals in the gate region. FENCE DEVIATION (packet Approach step 3 requires it): the five 79pt height pins live in ContinuumApp.swift, not the fence — re-anchored to slim-exact / card-bounded / rollup-vs-own-pre-fold-height. Witnesses red then restored green: stale table entry (healed rule), hardcoded 220 (source scan). |
| `P0.5-row-token-vocabulary.md` | done | this commit | 2026-08-04T01:05:58Z | Focus-session completion: SidebarSurfaceRole (new type — AgentSurfaceRole is pinned at 5 cases and its rowSelected/rowHover values are consumed live) with resting=panel identity and T3-mix alphas selected 0.07 < hover 0.08 < active 0.11; measured light 1.15/1.17/1.25 dark 1.18/1.21/1.32; LineWidth.hairline = 0.5 (ticket 93's token, sidebar first consumer); runSidebarSurfaceChecks gates ordering by measurement, 27 pairs x 2 themes, tile values pinned by hexKey. Nothing adopted in a view; 60 baselines byte-identical. Witnesses red then restored green: inverted hover/selected alphas (exit 1, ordering), hairline 0.5→1.0 (exit 1, pin). |
| `P1.1-remove-row-borders.md` | pending | — | — | — |
| `P1.2-interaction-fill-ladder.md` | pending | — | — | — |
| `P1.3-header-shelf-hairlines.md` | pending | — | — | — |
| `P1.4-focus-ring-and-floors.md` | pending | — | — | — |
| `P1.5-containment-supervised-review.md` | pending | — | — | — |
| `P2.1-title-line-ownership.md` | pending | — | — | — |
| `P2.2-measured-fit-tiers.md` | pending | — | — | — |
| `P2.3-content-derived-row-height.md` | pending | — | — | — |
| `P2.4-provider-glyph-meta-line.md` | pending | — | — | — |
| `P2.5-elapsed-formatter-column.md` | pending | — | — | — |
| `P2.6-slim-variant-parity.md` | pending | — | — | — |
| `P3.1-launch-reconciliation-sweep.md` | done | this commit | 2026-08-04T01:41:55Z | Focus-session completion (ahead of gate P3.6 per focus-session plan: true code deps only). ManagedSessionStatus gains .cancelled (system-cancel, distinct from user-stop) + isTerminal; ManagedSessionEndReason enum (NOT a String — I5-safe by construction) with endedReason on the record; schemaVersion 1→2 (rebuild through init IS the migration marker, since schemaVersion is a let). ManagedSessionReconciliation.reconcile skips terminal records WITHOUT writing and preserves lastSeenAt (never now — restamping poisons the elapsed anchor); Proof has internal init so no reader outside Core can compile an ungated listing read. Writer fixed: TileSpawner.swift spawnManagedAgent .starting → .running. Launch sweep at ContinuumApp boot before attachUI/restore/tile-walk/first-read; quit sweep best-effort in applicationWillTerminate. CoreChecks: isTerminal totality, v1 JSON swept and re-read AS BYTES (cancelled + continuumRestarted + schema 2, no "starting"), double-sweep byte AND backup-count identity. Witnesses red then restored green: N1 no-write skip dropped, N2 reader-only shortcut, N4 cancel collapsed onto stop, N5 reason dropped, N6 lastSeenAt restamped. HONEST LIMITS: N3 (read-only reinterpret passes decoded, fails bytes) NOT RUN — the byte assertion it targets is green and N1/N2 cover the write path; the .starting→.running writer half has NO deterministic red in this ticket (no matrix leg reads a fresh managed record's status word; --managed-agent-live-check is live-only and unwired), its witness is P3.2's pre-sweep-read-throws. Design §5.5 corrected: only ONE exhaustive switch over ManagedSessionStatus exists (agentRowStatus), so .cancelled forced one migration, not several. |
| `P3.2-gated-snapshot-read.md` | pending | — | — | — |
| `P3.3-single-status-owner.md` | pending | — | — | — |
| `P3.4-unconfirmed-frozen-clock.md` | pending | — | — | — |
| `P3.5-status-vocabulary-unification.md` | pending | — | — | — |
| `P3.6-status-supervised-review.md` | pending | — | — | — |
| `P4.1-agent-name-sentinel.md` | pending | — | — | — |
| `P4.2-first-prompt-name-seed.md` | pending | — | — | — |
| `P4.3-rename-guard-hardening.md` | pending | — | — | — |
| `P4.4-derived-child-naming.md` | pending | — | — | — |
| `P4.5-generated-name-oneshot.md` | pending | — | — | — |
| `P5.1-custom-row-context-menu.md` | pending | — | — | — |
| `P5.2-filter-band-scope-search.md` | pending | — | — | — |
| `P5.3-custom-bulk-action-bar.md` | pending | — | — | — |
| `P5.4-keyboard-traversal-jump-hints.md` | pending | — | — | — |
| `P5.5-width-resize-persistence.md` | pending | — | — | — |
| `P5.6-interaction-supervised-review.md` | pending | — | — | — |
| `P6.1-lifecycle-pure-derivation.md` | pending | — | — | — |
| `P6.2-auto-settle-window.md` | pending | — | — | — |
| `P6.3-snooze-derived-wake.md` | pending | — | — | — |
| `P6.4-attention-read-watermark.md` | pending | — | — | — |
| `P6.5-child-fanout-attention-rollup.md` | pending | — | — | — |
| `P6.6-accessibility-motion-sweep.md` | pending | — | — | — |
| `P7.1-final-supervised-acceptance.md` | pending | — | — | — |
