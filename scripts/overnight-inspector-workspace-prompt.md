# Autonomous inspector + workspace UX implementation loop

You are implementing Continuum inspector and workspace UX from local markdown tickets.

## Inputs

- Queue: `docs/2026-06-21-next-app-enhancement-loop/02-local-implementation-queue.md`
- Ticket directory: `docs/2026-06-21-next-app-enhancement-loop/`
- Style guide: `docs/37-ticket-authoring-style-guide.md`

## Operating rules

1. Pick the first unchecked queue item.
2. Read its source ticket fully before editing code.
3. Implement exactly that item. Do not perform adjacent improvements.
4. Add/extend deterministic app/core checks named in the ticket.
5. Write required QA artifacts under `qa-runs/...`.
6. Run at minimum:
   - `swift build`
   - the targeted new check(s)
   - `./scripts/run-matrix.sh --fast` unless the ticket is docs-only final audit
7. Update the queue item to `[x]` only after checks pass.
8. Commit exactly one logical commit for the item.
9. Emit one final line:
   - `LOOP: CONTINUE <item> fixed`
   - `LOOP: CONTINUE <item> audited`
   - `LOOP: STOP queue-empty`
   - `LOOP: STOP <reason>`

## Quality bar

- Product-path evidence beats pure model tests.
- Do not claim Safari/WebKit native inspector embedding. Build Continuum-native inspector only.
- Do not implement arbitrary JS eval, source editing, or generic connected tiles.
- Inspector relationship is narrow: inspector tile references one browser tile; deleting browser tile deletes/closes inspector tile.
- Console is logs-only.
- Workspace UI should reuse existing workspace runtime/sidebar/navigation/status plumbing; do not invent parallel systems.
- Stop rather than fake unsupported WebKit/network capabilities.

## Audit notes

For every item, if `PI_OVERNIGHT_RUN_DIR` is set, write a short note to:

`$PI_OVERNIGHT_RUN_DIR/audits/<item>.md`

Include:
- verdict;
- implementation summary;
- exact checks run;
- artifact paths;
- residual manual gaps.
