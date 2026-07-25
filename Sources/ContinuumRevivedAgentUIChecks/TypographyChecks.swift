import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.4-type-scale.md
//
// Deterministic checks for the type scale. Two failures matter most and are
// each framed by their counter-case: a role added later with NO style (totality
// would be an incomplete switch here, but a default arm would hide it), and a
// ladder whose steps collapse back to ~1pt — which is the state this ticket
// exists to leave, and which no compiler catches.
func runTypographyChecks() {
    // 1. Totality — every role has a style, and no style is degenerate. Driven
    //    off `allCases`, so a role added without a size is caught here.
    for role in TextRole.allCases {
        let style = Typography.style(for: role)
        expect(style.size >= Typography.minimumRenderedSize,
               "Typography: \(role.rawValue) must not be smaller than AppKit's smallest system size (\(Typography.minimumRenderedSize), got \(style.size))")
        expect(style.size <= 48,
               "Typography: \(role.rawValue) size \(style.size) is implausible for desktop chrome")
    }
    // titleL carries the weight the agent tile's 18pt glyph already ships, so
    // adopting the role in P1.10 restyles nothing. Pinned, because a drift to
    // semibold here would be an invisible visual change at the call site.
    expect(Typography.style(for: .titleL) == TextStyle(size: 18, weight: .bold, monospaced: false),
           "Typography: titleL must stay 18pt bold — the agent tile's existing glyph style")
    expect(TextRole.allCases.count == 7,
           "Typography: expected 7 roles (got \(TextRole.allCases.count): \(TextRole.allCases.map(\.rawValue)))")

    // 2. The ladder is monotonic AND actually visible. `>` alone would bless
    //    18/13/12/11/10 — the near-collapsed scale this ticket replaces — so the
    //    step floor is the load-bearing half of this assertion.
    expect(Typography.sizeLadder == [.titleL, .title, .body, .label, .caption],
           "Typography: sizeLadder must be the five hierarchy roles largest-first (got \(Typography.sizeLadder.map(\.rawValue)))")
    for (larger, smaller) in zip(Typography.sizeLadder, Typography.sizeLadder.dropFirst()) {
        let step = Typography.style(for: larger).size - Typography.style(for: smaller).size
        expect(step >= Typography.minimumLadderStep,
               "Typography: \(larger.rawValue) → \(smaller.rawValue) steps \(step)pt, below the \(Typography.minimumLadderStep)pt minimum — the hierarchy would not read")
    }

    // 3. Mono roles are monospaced, non-mono roles are not, and every mono role
    //    is its base role plus that one flag. Without the pairing assertion a
    //    mono size could drift off the ladder unnoticed.
    let monoPairs: [(mono: TextRole, base: TextRole)] = [(.bodyMono, .body), (.captionMono, .caption)]
    let monoRoles = Set(monoPairs.map(\.mono))
    for role in TextRole.allCases {
        expect(Typography.style(for: role).monospaced == monoRoles.contains(role),
               "Typography: \(role.rawValue).monospaced must be \(monoRoles.contains(role))")
    }
    for pair in monoPairs {
        let mono = Typography.style(for: pair.mono)
        let base = Typography.style(for: pair.base)
        expect(mono.size == base.size && mono.weight == base.weight,
               "Typography: \(pair.mono.rawValue) must match \(pair.base.rawValue) in size and weight (got \(mono.size)/\(mono.weight.rawValue) vs \(base.size)/\(base.weight.rawValue))")
    }
    expect(TextRole.allCases.filter { Typography.style(for: $0).monospaced }.count == monoPairs.count,
           "Typography: exactly \(monoPairs.count) roles may be monospaced")

    // 4. Zoom composition. The numbers are the arithmetic the documented
    //    statement in Typography.swift makes, pinned so the comment cannot rot:
    //    at the `.managedAgent` readability threshold (0.70x, owned by
    //    ReadabilityPolicy in Core) only titleL/title/body/bodyMono survive.
    let managedAgentThreshold = 0.70
    let legibleAtThreshold = TextRole.allCases.filter { Typography.isLegible($0, atZoom: managedAgentThreshold) }
    expect(Set(legibleAtThreshold) == Set([.titleL, .title, .body, .bodyMono]),
           "Typography: at \(managedAgentThreshold)x exactly titleL/title/body/bodyMono may be legible (got \(legibleAtThreshold.map(\.rawValue)))")
    // …and BELOW it the set shrinks immediately. Checking only the boundary
    // would let the comment claim "at or below 0.70x" — which is false, since
    // body needs 0.6923x. `.overviewLabelOnly` really does mean no body text.
    let legibleBelowThreshold = TextRole.allCases.filter { Typography.isLegible($0, atZoom: 0.69) }
    expect(Set(legibleBelowThreshold) == Set([.titleL, .title]),
           "Typography: at 0.69x only titleL/title may be legible (got \(legibleBelowThreshold.map(\.rawValue)))")
    expect(TextRole.allCases.allSatisfy { !Typography.isLegible($0, atZoom: 0.49) },
           "Typography: no role may be legible at 0.49x — a tile that far out cannot carry type at all")
    // The exact rungs the file documents, so the comment cannot drift.
    let documentedZooms: [(TextRole, Double)] = [
        (.titleL, 0.50), (.title, 0.60), (.body, 0.6923), (.bodyMono, 0.6923),
        (.label, 0.8182), (.caption, 1.0), (.captionMono, 1.0)
    ]
    expect(documentedZooms.count == TextRole.allCases.count,
           "Typography: every role needs a documented minimum legible zoom")
    for (role, expected) in documentedZooms {
        let actual = Typography.minimumLegibleZoom(for: role)
        expect(abs(actual - expected) < 0.0001,
               "Typography: \(role.rawValue) minimumLegibleZoom must be \(expected) as documented (got \(actual))")
    }
    expect(Typography.minimumLegibleSize(atZoom: 0.5) == Typography.minimumRenderedSize * 2,
           "Typography: halving the zoom must double the minimum legible size")
    expect(Typography.minimumLegibleSize(atZoom: 0) == .infinity,
           "Typography: a non-positive zoom must report nothing as legible")
    expect(!Typography.isLegible(.body, atZoom: 0),
           "Typography: no role is legible at zoom 0")
    // The packet's own example: an 11pt label at 0.35x renders ~4pt.
    expect(!Typography.isLegible(.label, atZoom: 0.35),
           "Typography: label must not be legible at 0.35x (renders \(Typography.style(for: .label).size * 0.35)pt)")
    for role in TextRole.allCases {
        let zoom = Typography.minimumLegibleZoom(for: role)
        expect(Typography.isLegible(role, atZoom: zoom),
               "Typography: \(role.rawValue) must be legible at its own minimumLegibleZoom (\(zoom))")
        expect(!Typography.isLegible(role, atZoom: zoom * 0.99),
               "Typography: \(role.rawValue) must NOT be legible just below its minimumLegibleZoom (\(zoom))")
    }
    // Caption is a 1:1-only role — any zoom-out drops it. Stated as a number so
    // shrinking caption below the floor, or raising the floor, goes red.
    expect(Typography.minimumLegibleZoom(for: .caption) == 1.0,
           "Typography: caption must be legible only at 1.0x and above (got \(Typography.minimumLegibleZoom(for: .caption)))")

    let ladder = Typography.sizeLadder.map { "\($0.rawValue) \(Int(Typography.style(for: $0).size))" }.joined(separator: " > ")
    print("Typography checks passed: \(TextRole.allCases.count) roles, ladder \(ladder) (min step \(Int(Typography.minimumLadderStep))pt), \(monoPairs.count) mono roles mirror their base, \(legibleAtThreshold.count) roles legible at 0.70x")
}
