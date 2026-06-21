# T10 — Final audit and dogfood for inspector loop

Status: implementation-ready audit ticket

## Goal
Before merging the inspector loop, produce an artifact-backed recommendation: keep, fix-forward, or revert each inspector/browser UX ticket.

## Scope
- Read all T01–T09 audit artifacts and commits.
- Run `./scripts/run-matrix.sh --fast` from clean tree.
- Run targeted inspector checks from clean app support/project roots.
- Write final recommendation doc.

## Required manual dogfood checklist
Human should verify, or ticket must mark pending:
- Open browser tile.
- Open Continuum Inspector Tile without Safari.
- Elements panel shows real DOM.
- Selecting element highlights browser content.
- Console panel shows `console.log` from page.
- Styles panel shows computed styles for selected element.
- Network-lite honestly shows navigation events and labels unsupported fields.
- Deleting browser tile leaves inspector disconnected without crash.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-final-audit/manifest.json
```

Required fields:
- `matrixFastPassed`
- `ticketsReviewed`
- `manualDogfoodStatus`
- `recommendation: keep|fix-forward|revert`
- `knownGaps`

## Stop conditions
If any ticket lacks artifact evidence, do not recommend merge. Produce fix-forward tickets instead.
