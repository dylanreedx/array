import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.4-type-scale.md
//
// The one assertion that cannot live in ContinuumRevivedAgentUIChecks. That
// target depends on AgentUI ALONE (P1.1, deliberately), so `Typography`'s
// documented composition with `ReadabilityPolicy` — "at the `.managedAgent`
// readability threshold only titleL/title/body/bodyMono are legible" — would
// otherwise be pinned against a hardcoded 0.70 that stays green forever if Core
// moves the band boundary.
//
// So: DERIVE the boundary from `ReadabilityPolicy` itself, and hold the type
// scale to it. Typography still does not import Core; this check is the seam.
func runTypographyReadabilityChecks() {
    let target = ReadabilityTargetKind.tile(.managedAgent)

    // Lowest zoom at which a managed-agent tile is more than a label. Scanned in
    // 0.005 steps from the policy floor rather than written down, so the number
    // below is Core's answer, not a copy of it.
    var boundary: Double?
    var zoom = ReadabilityPolicy.minimumPolicyZoom
    while zoom <= 1.0 + 1e-9 {
        if ReadabilityPolicy.band(for: target, zoom: zoom) != .overviewLabelOnly {
            boundary = zoom
            break
        }
        zoom += 0.005
    }
    guard let boundary else {
        fputs("FAIL: TypographyReadability: ReadabilityPolicy never leaves .overviewLabelOnly for .managedAgent up to 1.0x\n", stderr)
        Foundation.exit(1)
    }
    expect(abs(boundary - 0.70) < 0.006,
           "TypographyReadability: the .managedAgent readable boundary moved to \(boundary) — Typography's documented role legality was written against 0.70x and must be re-ruled")

    // At the boundary: body text is legible, so a `.readableSummary` can
    // actually be prose.
    let legibleAtBoundary = Set(TextRole.allCases.filter { Typography.isLegible($0, atZoom: boundary) })
    expect(legibleAtBoundary == Set([.titleL, .title, .body, .bodyMono]),
           "TypographyReadability: at the derived boundary \(boundary)x exactly titleL/title/body/bodyMono must be legible (got \(legibleAtBoundary.map(\.rawValue).sorted()))")

    // Just inside `.overviewLabelOnly`: body text is NOT legible. This is the
    // half that gives the band its meaning — an overview tile cannot be the same
    // content set smaller.
    let below = boundary - 0.01
    expect(ReadabilityPolicy.band(for: target, zoom: below) == .overviewLabelOnly,
           "TypographyReadability: \(below)x must still be .overviewLabelOnly")
    expect(!Typography.isLegible(.body, atZoom: below) && !Typography.isLegible(.bodyMono, atZoom: below),
           "TypographyReadability: body/bodyMono must be illegible at \(below)x, inside .overviewLabelOnly")
    expect(Typography.isLegible(.titleL, atZoom: below),
           "TypographyReadability: titleL must survive at \(below)x — an overview tile still has to name itself")

    // And at the editable band a managed-agent tile can carry every role except
    // the 1:1-only captions.
    let editableZoom = 0.90
    expect(ReadabilityPolicy.editingReliable(for: target, zoom: editableZoom),
           "TypographyReadability: \(editableZoom)x must be .editableDetail for .managedAgent")
    expect(Typography.isLegible(.label, atZoom: editableZoom),
           "TypographyReadability: label must be legible wherever editing is reliable")

    print("TypographyReadability checks passed: boundary derived at \(String(format: "%.3f", boundary))x from ReadabilityPolicy, \(legibleAtBoundary.count) roles legible there, body illegible at \(String(format: "%.2f", below))x")
}
