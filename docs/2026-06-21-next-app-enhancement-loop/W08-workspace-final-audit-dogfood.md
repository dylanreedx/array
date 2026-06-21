# W08 — Workspace UX final audit and dogfood

Status: implementation-ready audit ticket

## Goal
Before merging workspace UX work, produce an artifact-backed keep/fix/revert recommendation and dogfood checklist.

## Scope
- Review W01–W07 commits/artifacts.
- Run `./scripts/run-matrix.sh --fast` from clean tree.
- Run all workspace sidebar/topbar targeted checks.
- Write final recommendation.

## Manual dogfood checklist
Human should verify, or ticket must mark pending:
- Sidebar visible by default and does not make canvas feel cramped.
- Workspace switch from sidebar feels faster/more understandable than palette-only.
- Current workspace identity is always obvious.
- Agent status glyphs are useful, not noisy.
- Hidden sidebar mode remains usable.
- No confusion between workspace, project, zone, and tile labels.

## QA artifact

```text
qa-runs/<timestamp>/workspace-ux-final-audit/manifest.json
```

Required fields:
- `ticketsReviewed`
- `matrixFastPassed`
- `manualDogfoodStatus`
- `recommendation`
- `knownGaps`
