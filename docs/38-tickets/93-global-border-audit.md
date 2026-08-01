# Global border audit — 0.5 pt maximum

**Ticket 93 · created 2026-07-31 · owner-directed (Queue 91 P4.10 composer review)**

## Why / sequencing

During the supervised P4.10 composer review the owner set a direction broader than any Queue 91
fence: **all app borders should be no larger than 0.5 pt.** The dropdown corrections in P4.10 apply
this only to `ChoiceButton`/`ChoiceListView`, deliberately — the program-wide requirement must be
an explicit token/audit ticket rather than being smuggled into one component patch. This ticket is
that expansion.

Do not start this while the Queue 91 loop is running: it will touch files inside active Queue 91
fences, and P4.10/P5.x reviews assume their fences are otherwise quiet. Sequence it after Queue 91
P5.5 acceptance (or slot it as an explicit queue with its own fences if it becomes urgent).

## Scope

1. **Token-level rule.** Establish the 0.5 pt maximum as a design-token constraint in
   `ContinuumRevivedAgentUI` (and the app-level token layer if separate), so a component cannot
   express a heavier decorative or idle border through the token system. Hairline width becomes a
   named token, not a per-view literal.
2. **Audit.** Inventory every `borderWidth`, stroke, and outline in `Sources/` (app and Component
   Lab): record component, width, role (decorative containment, control boundary, selection,
   keyboard focus, error/warning), and both-theme appearance.
3. **Correct.** Reduce decorative and idle-control borders to ≤ 0.5 pt or remove them in favor of
   quiet fills, per the Queue 91 `_DESIGN.md` "soft hierarchy, not perimeter borders everywhere"
   direction.
4. **Focus stays visible.** Keyboard focus, selection, and exceptional attention must remain
   immediately obvious in both themes **without** reverting to thick grey borders — use accent,
   fill, glow, or another non-permanent cue. No existing focus-visibility, contrast, or
   accessibility assertion may be weakened. If a focus treatment currently depends on a >0.5 pt
   grey ring, replace the treatment; do not exempt the component.

## Constraints

- Interactive boundaries, focus, selection, and meaningful status keep their contrast
  requirements (3:1 non-text where they carry meaning); decorative hairlines do not need 3:1.
  Text contrast stays AA in both themes with zero exemptions.
- Retina note: 0.5 pt renders as 1 device pixel at 2×. Audit any 1× fallback behavior rather than
  assuming it.
- No visual baseline may move outside a supervised review; this ticket ends in its own supervised
  visual gate with both-theme review images.

## Done when

- A width token (or equivalent compile-checked rule) makes >0.5 pt decorative/idle borders
  unexpressible, with a deterministic audit check that fails on new violations and a recorded
  negative witness.
- The audit inventory is committed alongside the corrections; every remaining >0.5 pt line is one
  of: keyboard focus, selection, or exceptional attention, each justified in the inventory.
- Owner reviews and approves the corrected surfaces in both themes.

## Verify

```bash
swift build
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
```

Plus the new border-audit check added by this ticket, and the existing appearance/contrast/geometry
legs for every touched component.
