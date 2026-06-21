# Epics and implementation queue

Status: draft, ready for review before overnight loop

## Epic A — In-app browser inspector tile

Goal: users can inspect a browser tile without opening Safari. This is a Continuum-native inspector, not Safari Web Inspector.

Design decision:
- Add a new inspector tile kind or browser-inspector tile runtime that stores `inspectedBrowserTileId`.
- Keep the relationship narrow and typed. Do not create generic connected tiles yet.
- Inspector capabilities are implemented via safe JavaScript evaluation, WebKit delegates, and app-side event capture.

Tickets:
1. T01 — Inspector tile shell and persistence
2. T02 — DOM tree snapshot + element selection
3. T03 — Console log bridge
4. T04 — Computed styles panel
5. T05 — Network-lite request log
6. T06 — Inspector/browser link lifecycle
7. T07 — Palette/menu actions

## Epic B — Browser operator UX

Goal: make browser state and activity more transparent as users run many browser tiles.

Tickets:
8. T08 — Downloads tile / downloads drawer
9. T09 — Browser session health panel

## Epic C — Final audit

Goal: prevent shallow completion.

Tickets:
10. T10 — Final audit and dogfood checklist

## Queue rules for autonomous loop

- One ticket per iteration.
- One organized commit per ticket.
- Every ticket must write or update a QA artifact under `qa-runs/...`.
- If WebKit/private API blocks native inspector parity, stop and document exact limitation; do not fake Safari DevTools parity.
- If a ticket requires product clarification, mark it blocked and move to the next implementation-ready ticket.

## Open product questions for Dylan

1. Should inspector tiles be allowed to outlive their inspected browser tile as a disconnected historical snapshot, or should they close/empty when the browser tile is deleted?
   - Dylan decision: delete/close inspector tile when its inspected browser tile is deleted.
2. Should clicking an element in the DOM tree highlight it in the browser tile?
   - Dylan decision: yes, temporary overlay/highlight.
3. Do we want source editing in inspector?
   - Dylan decision: no; read-only inspection only.
4. Should console support arbitrary JS evaluation?
   - Dylan decision: no; logs only.
