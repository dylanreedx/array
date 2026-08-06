# P7.1 gate prep — final sidebar acceptance

Refreshed 2026-08-06 after night 3 at implementation commit `fe7257d`.
**Status: NOT READY; P7.1 remains pending.**

## Open prerequisites

The autonomous implementation program is complete: `_LEDGER.md` records 37/40 done. The only
pending rows are the three supervised gates:

- P3.6 owner status-truthfulness/relaunch review;
- P5.6 owner native-interaction/VoiceOver review;
- P7.1 final acceptance itself.

No baseline was blessed and no owner approval was inferred overnight. STOP remains armed and the
loop remains stopped.

The requested **release** build failed on strict-concurrency diagnostics in check-only
`ContinuumApp.swift` closures; the log is `qa-runs/night3-candidate/build.log`. A debug fallback
bundle now exists at `qa-runs/night3-candidate/Continuum Revived.app`; it is sourced from
`.build/debug`, ad-hoc signed, verified on disk, and was not launched. Its exact state is recorded in
`qa-runs/night3-candidate/STATUS`. Packaging source was deliberately not repaired during the handoff.
P7.1 still needs Dylan to choose that fallback or produce an exact verified-fresh release candidate.

## Acceptance bundle after P3.6 and P5.6

1. Record the exact accepted commit; require a clean tracked tree and an artifact built from it.
2. Quit the owner's running instance, confirm built-in Retina Main, and install the verified-fresh
   app.
3. Populate realistic live, needs-action, failed, unconfirmed/frozen, settled, snoozed, fan-out,
   headless, nameless, first-prompt, manual, and generated-name states.
4. Walk 220/280/320 in Aqua and Dark Aqua.
5. Exercise every row action, filter/search, bulk action, keyboard/jump path, rename/generation race,
   resize, lifecycle move, VoiceOver, Reduce Motion, Increase Contrast, and full keyboard access.
6. Run the **unskipped** full matrix, including supervised surface legs, then each named focused leg
   five consecutive times to expose ordering and flakiness. No P7.1 run has done this yet.
7. Inventory every baseline move. Inspect and bless only with built-in Retina Main green and explicit
   owner approval.
8. Ask the four P7.1 acceptance questions. Record corrections as tickets, never silent patches.
9. Record the accepted commit and honest limits, relaunch that exact build for the owner, and only
   then mark P7.1 done.

## Required commands when ready

```bash
swift build
.build/debug/continuum-revived --sidebar-ux-check
.build/debug/continuum-revived --agent-inbox-check
.build/debug/continuum-revived --ui-geometry-check
.build/debug/continuum-revived --ui-contrast-check
.build/debug/continuum-revived --ui-probe-check
.build/debug/continuum-revived --component-lab-check
.build/debug/continuum-revived --ui-baseline-check
.build/debug/continuum-revived --agent-status-check
swift scripts/check-retina-main.swift
./scripts/run-matrix.sh
```

## Honest limits to carry into acceptance

- P2.4 was never independently reviewed because its protocol failure preceded review.
- Every Phase-5 ticket ended on a supervisor-only repair after the two-review maximum.
- P2.2's `.abbreviated` tier remains unreachable in the P0.3 corpus.
- P3.1's N3 read-only-reinterpret witness was not run.
- No `AgentStatus.failed` exists, so the phone says `idle` where tile/sidebar say `Failed`.
- Phase 6 makes `.settled`, `.snoozed`, and the slim variant reachable in the shipped app for the
  first time; earlier phases tested several of those surfaces only in fixtures.

Hard rails remain: no approval by silence, no blessing to make red disappear, no lowered floor,
tolerance, or count, and no app probe while another Continuum instance owns the store or tmux.
