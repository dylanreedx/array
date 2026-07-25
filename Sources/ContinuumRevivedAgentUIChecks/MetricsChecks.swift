import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.5-spacing-radius-scale.md
//
// Deterministic checks for the spacing/radius scale. Three failures matter and
// none of them is a compile error: a spacing value drifting off the 2pt grid, a
// container radius sliding back below its nested cards' radius (today's state,
// tile 6 nesting cards 8 — the regression witness), and `rowHeight` losing its
// dependence on type, which is the only thing keeping P1.4's size moves from
// clipping a row.
//
// Five negative tests were observed red at exit 1 with the final code:
//
//   Radius card 6→8, container 10→6 (today's shipped nesting)
//     FAIL: Radius: container (6.0) must exceed card (8.0) — …
//   Space.s 4→5
//     FAIL: Space: 5.0 is off the 2.0pt grid
//   Metrics.lineHeightMultiple 1.25→1.1
//     FAIL: Metrics: lineHeight(titleL) = 20.0 is below AppKit's own 21.0 for 18.0pt — the row would clip
//   rowHeight dropping its `lines` factor
//     FAIL: Metrics: rowHeight must grow with line count (1 → 2)
//   Inset.row vertical Space.m→10 (a fresh number instead of a ladder value)
//     FAIL: Inset: row.top = 10.0 is not a Space ladder value [2.0, 4.0, 8.0, 12.0, 16.0, 24.0]
func runMetricsChecks() {
    // 1. The spacing ladder: on the grid, strictly increasing, positive.
    for value in Space.ladder {
        expect(value > 0, "Space: \(value) must be positive")
        expect((value / Space.grid).rounded() * Space.grid == value,
               "Space: \(value) is off the \(Space.grid)pt grid")
    }
    for (smaller, larger) in zip(Space.ladder, Space.ladder.dropFirst()) {
        expect(larger > smaller,
               "Space: ladder must be strictly increasing (got \(smaller) then \(larger))")
    }
    expect(Space.ladder == [2, 4, 8, 12, 16, 24],
           "Space: ladder must be 2/4/8/12/16/24 (got \(Space.ladder))")

    // 2. Radius. `container > card` is the load-bearing line: it is exactly the
    //    inverted nesting shipping today (TileNSView 6 containing cards at 8).
    expect(Radius.container > Radius.card,
           "Radius: container (\(Radius.container)) must exceed card (\(Radius.card)) — a container inside its own cards' radius is the inverted nesting this ticket fixes")
    expect(Radius.card > 0, "Radius: card must be positive")
    // A pill has to survive being clamped to half of any height the agent UI
    // ever gives a chip. The tallest is a tile-scale row; anything below that
    // and `pill` would round a corner instead of closing it.
    expect(Radius.pill >= Metrics.rowHeight(for: .titleL, lines: 4),
           "Radius: pill (\(Radius.pill)) must be at least any real control height, so halving it in a view still clamps to fully round")

    // 3. Insets are built out of the ladder, not out of fresh numbers — that is
    //    what collapses today's 3/6/8/10/12 vertical paddings into two shapes.
    let insets: [(name: String, token: EdgeInsetsToken)] = [("card", Inset.card), ("row", Inset.row)]
    for entry in insets {
        for (edge, value) in [("top", entry.token.top), ("left", entry.token.left),
                              ("bottom", entry.token.bottom), ("right", entry.token.right)] {
            expect(Space.ladder.contains(value),
                   "Inset: \(entry.name).\(edge) = \(value) is not a Space ladder value \(Space.ladder)")
        }
        expect(entry.token.top == entry.token.bottom && entry.token.left == entry.token.right,
               "Inset: \(entry.name) must be symmetric (got \(entry.token))")
        expect(entry.token.vertical == entry.token.top * 2 && entry.token.horizontal == entry.token.left * 2,
               "Inset: \(entry.name) vertical/horizontal must sum both edges")
    }
    // Horizontal rhythm is shared so text left-aligns down a whole tile; only
    // the vertical padding distinguishes a row from a card.
    expect(Inset.card.horizontal == Inset.row.horizontal,
           "Inset: card and row must share horizontal padding (got \(Inset.card.horizontal) vs \(Inset.row.horizontal))")
    expect(Inset.row.vertical < Inset.card.vertical,
           "Inset: a row must be vertically tighter than a card (got \(Inset.row.vertical) vs \(Inset.card.vertical))")

    // 4. Line height never under-reports AppKit. These are the measured
    //    `NSLayoutManager.defaultLineHeight(for:)` values quoted in
    //    Metrics.swift's PROVENANCE note (macOS 15) — pinned here so the
    //    multiple cannot be lowered into clipping territory.
    let measuredDefaultLineHeights: [(size: Double, appKit: Double)] = [
        (9, 11), (11, 13), (13, 16), (15, 18), (18, 21)
    ]
    for role in TextRole.allCases {
        let size = Typography.style(for: role).size
        guard let measured = measuredDefaultLineHeights.first(where: { $0.size == size }) else {
            expect(false, "Metrics: no measured AppKit line height for \(role.rawValue) at \(size)pt — add one before changing the ladder")
            return
        }
        let derived = Metrics.lineHeight(for: role)
        expect(derived >= measured.appKit,
               "Metrics: lineHeight(\(role.rawValue)) = \(derived) is below AppKit's own \(measured.appKit) for \(size)pt — the row would clip")
        expect(derived == derived.rounded(),
               "Metrics: lineHeight(\(role.rawValue)) = \(derived) must be a whole point")
    }
    // Every ladder size is covered, so the loop above cannot pass by checking a
    // narrower set than the type scale actually ships.
    expect(Set(measuredDefaultLineHeights.map(\.size)) == Set(TextRole.allCases.map { Typography.style(for: $0).size }),
           "Metrics: the measured line-height table must cover exactly the shipped role sizes")

    // 5. rowHeight is a function of type, in both variables. Without these two
    //    it could quietly become a constant again, which is the failure mode
    //    the hardcoded 52/44/24 are.
    for lines in 1..<4 {
        expect(Metrics.rowHeight(for: .body, lines: lines + 1) > Metrics.rowHeight(for: .body, lines: lines),
               "Metrics: rowHeight must grow with line count (\(lines) → \(lines + 1))")
    }
    for (larger, smaller) in zip(Typography.sizeLadder, Typography.sizeLadder.dropFirst()) {
        expect(Metrics.rowHeight(for: larger) > Metrics.rowHeight(for: smaller),
               "Metrics: rowHeight(\(larger.rawValue)) must exceed rowHeight(\(smaller.rawValue))")
    }
    // The arithmetic itself, so a change of shape (insets dropped, lines
    // ignored) is named rather than absorbed.
    expect(Metrics.rowHeight(for: .body, lines: 2) == 2 * Metrics.lineHeight(for: .body) + Inset.row.vertical,
           "Metrics: rowHeight must be lines x lineHeight + insets.vertical")
    expect(Metrics.rowHeight(for: .body, insets: Inset.card) > Metrics.rowHeight(for: .body, insets: Inset.row),
           "Metrics: rowHeight must honour the insets it is given")
    expect(Metrics.rowHeight(for: .body, lines: 0) == Metrics.rowHeight(for: .body, lines: 1),
           "Metrics: a non-positive line count must clamp to one line, not collapse the row")
    expect(Metrics.rowHeight(for: .body, lines: -3) == Metrics.rowHeight(for: .body, lines: 1),
           "Metrics: a negative line count must clamp to one line")
    // The three heights Metrics.swift documents for P1.10, so that comment
    // cannot drift from the tokens.
    expect(Metrics.rowHeight(for: .title, lines: 2) == 54,
           "Metrics: a two-line title row must be 54pt as documented (got \(Metrics.rowHeight(for: .title, lines: 2)))")
    expect(Metrics.rowHeight(for: .body, insets: Inset.card) == 41,
           "Metrics: a card-inset body row must be 41pt as documented (got \(Metrics.rowHeight(for: .body, insets: Inset.card)))")
    expect(Metrics.rowHeight(for: .body) == 33,
           "Metrics: a row-inset body row must be 33pt as documented (got \(Metrics.rowHeight(for: .body)))")

    print("Metrics checks passed: \(Space.ladder.count) spacing steps on a \(Int(Space.grid))pt grid, container radius \(Int(Radius.container)) > card \(Int(Radius.card)), \(TextRole.allCases.count) roles clear AppKit's own line heights, rowHeight derives from type")
}
