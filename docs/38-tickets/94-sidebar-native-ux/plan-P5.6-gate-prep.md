# P5.6 gate prep — native interaction

Refreshed 2026-08-06 after night 3 at implementation commit `fe7257d`.
**Status: READY FOR OWNER REVIEW; P5.6 remains pending.** No approval was inferred, no app was
launched, and no baseline was blessed.

## What is ready now

P5.1–P5.5 are all complete. The gate can now judge the native interaction surface as one whole:

- custom ChoiceList row context menu and capability gating;
- fixed scope/search filter band and workspace-management choices;
- multi-selection custom bulk bar and host-owned destructive confirmation;
- native keyboard traversal, preview, jump hints, and text-editor shortcut withholding;
- dynamic divider resize and mouse-up persistence above the old 420pt ceiling;
- P4 inline/manual/derived/generated naming, including request CAS;
- P6.6 VoiceOver hierarchy, Reduce Motion, and Increase Contrast behavior.

The final focused checks and headless matrix passed. All five Phase-5 tickets exhausted two review
rounds and ended with supervisor-only repairs; P5.6 must inspect those repairs together rather than
treating green unit checks as visual evidence.

Prepared owner materials are in `qa-runs/p5.6-gate/`:

- `REVIEW.md` — the exact live walk and owner questions;
- `gate.sh` — preflight, deterministic checks, and non-blessing baseline comparison;
- `preflight-night3.log` — owner instance clear, STOP/loop state, candidate identity, Retina Main.

## Candidate caveat

The requested **release** build was attempted from
`fe7257d1db93448a335f60a3faaf909dcfb1fb1a` and failed on strict-concurrency errors in check-only
closures in `ContinuumApp.swift`; the complete log is `qa-runs/night3-candidate/build.log`. Per the
night-3 handoff, source was not patched for packaging. A debug fallback bundle now exists at
`qa-runs/night3-candidate/Continuum Revived.app`; it was assembled from `.build/debug`, ad-hoc signed,
verified on disk, and not launched. `qa-runs/night3-candidate/STATUS` records the exact commit,
configuration, hashes, and verification state. Dylan must deliberately choose that fallback or
repair/rebuild release before the live owner walk.

## Owner gate

1. Confirm STOP is armed, the loop is stopped, the owner instance is quit, and the reviewed commit
   matches the candidate.
2. Run `qa-runs/p5.6-gate/gate.sh preflight`, then `gate.sh checks`.
3. In an installed candidate, drive menu, filter/search, bulk actions, traversal/jumps, resize,
   inline rename, first-prompt naming, manual rename, generation, and rename-vs-generation race at
   220/280/320 in Aqua and Dark Aqua.
4. Exercise VoiceOver, Reduce Motion, Increase Contrast, and full keyboard access on every new
   surface. Confirm no stock `NSMenu`, `NSPopUpButton`, bezeled `NSTextField`, or default focus ring
   is visible or reachable.
5. Run `gate.sh baselines` only with built-in Retina Main green. Inspect every actual/diff image
   before any explicit blessing.
6. Ask whether the menu feels like Continuum, the whole sidebar works without a mouse, the names
   read as human names, and any stock AppKit remains.

Corrections become tickets; silence is not approval. Do not mark P5.6 done until Dylan explicitly
approves or records corrections.

## Known baseline inventory

No baseline has been blessed since P1.5. The current chrome worksheet has 60 PNGs: 38
byte-identical, 12 obsolete 320×652 agent-inbox keys to delete, 12 new 320×660 renders without a
committed baseline, and 10 real sidebar/activity-dock diffs. The separate Component Lab leg retains
five last-known managed-agent tile candidates whose cause remains unproved. Never use external-
display 1× results or raise a tolerance to make the gate green.
