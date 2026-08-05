# P5.6 gate prep — native interaction

Prepared 2026-08-05 after night 2. **Status: NOT READY; P5.6 remains pending.**

## Why it is not ready

P4.1–P4.5 landed, including inline rename and the R7 Pi one-shot. None of P5.1–P5.5 landed. The
night's cut order dropped P5.5, then P5.4, then P5.2; P5.1/P5.3 were not started before the 05:15
cutoff. A supervised review cannot honestly judge menu, filter, bulk bar, keyboard traversal, and
resize as one native whole while those implementations are absent.

Do not create or bless a P5.6 baseline set and do not mark the gate done until all five autonomous
P5 rows are complete. There is intentionally no `qa-runs/p5.6-gate/` yet.

## What is already available to review later

- P4.3 live inline rename: body-only double click, Return/Escape/blur, no trailing activation, CAS.
- P4.4 stable derived/child naming precedence.
- P4.5 explicit Generate Name action through a bounded `pi --no-session` one-shot.
- Final headless matrix green at `83b10a9`.
- Current UI baseline inventory: 22 changed / 38 matched; none blessed.

## Build the gate only after P5 lands

1. Confirm STOP is armed and the loop is stopped.
2. Quit the owner's Continuum instance before any build/probe/relaunch.
3. Require a clean tracked tree and run the program guard.
4. Build an installed candidate from the exact reviewed HEAD.
5. At 220/280/320 in both appearances, drive:
   - custom row context menu and capability/tooltips;
   - scope/filter/search band;
   - multi-selection and custom bulk bar;
   - full keyboard traversal and jump hints;
   - divider resize/persistence;
   - inline rename and generated-name race.
6. Exercise VoiceOver, Reduce Motion, and full keyboard access on every new surface.
7. Structurally confirm no stock `NSMenu`, `NSPopUpButton`, bezeled `NSTextField`, or default focus
   ring is reachable.
8. Run both baseline legs with Retina Main green; inspect before blessing.
9. Ask for explicit owner approval. Corrections become tickets; silence is not approval.

## Mechanical commands when ready

```bash
swift build
.build/debug/continuum-revived --sidebar-ux-check
.build/debug/continuum-revived --ui-geometry-check
.build/debug/continuum-revived --ui-contrast-check
.build/debug/continuum-revived --component-lab-check
.build/debug/continuum-revived --ui-baseline-check
swift scripts/check-retina-main.swift
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
```

Do not lower a floor/tolerance/count or bless merely to pass.
