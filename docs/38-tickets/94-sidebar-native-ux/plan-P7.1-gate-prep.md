# P7.1 gate prep — final sidebar acceptance

Prepared 2026-08-05 after night 2. **Status: NOT READY; P7.1 remains pending.**

## Open prerequisites

- P3.6 owner status-truthfulness review is pending.
- P5.1–P5.5 and P5.6 are pending.
- P6.1–P6.6 are pending.
- No overnight baseline was blessed.

Current program state is 26/40 done at `83b10a9`. STOP is armed and the loop is stopped. Do not infer
acceptance from the green headless matrices or from the unattended night.

## Acceptance bundle to assemble after prerequisites land

1. Record the exact final commit and require a clean tracked tree.
2. Quit the owner's running instance; confirm Retina Main; build and install a verified-fresh app.
3. Populate realistic states: live, needs-action, failed, unconfirmed/frozen, settled, snoozed,
   fan-out parent/children, headless, and newly spawned nameless/first-prompt/generated-name agents.
4. Walk 220/280/320 in Aqua and Dark Aqua.
5. Exercise every row action, filter/search, bulk action, keyboard/jump path, rename/generation race,
   resize, lifecycle move, VoiceOver, Reduce Motion, and full keyboard access.
6. Run the full matrix including supervised surface legs, then each named focused leg five consecutive
   times to expose ordering/flakiness.
7. Inventory every baseline move; inspect and bless only with Retina Main green and explicit owner
   approval.
8. Ask the four acceptance questions in P7.1. Record corrections as tickets, not silent patches.
9. Record the accepted commit and honest limits, relaunch that exact build for the owner, then and
   only then mark P7.1 done.

## Required commands when ready

```bash
swift build
.build/debug/continuum-revived --sidebar-ux-check
.build/debug/continuum-revived --agent-inbox-check
.build/debug/continuum-revived --ui-geometry-check
.build/debug/continuum-revived --ui-contrast-check
.build/debug/continuum-revived --component-lab-check
.build/debug/continuum-revived --ui-baseline-check
.build/debug/continuum-revived --agent-status-check
swift scripts/check-retina-main.swift
./scripts/run-matrix.sh
```

Hard rails remain: no approval by silence, no baseline blessing to make red disappear, no lowered
floor/tolerance/count, and no app probe while another Continuum instance owns the store/tmux.
