import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// Per-component Layer-1 check suite for the StatusChip — the first agent-UI
// building block. Moved from ContinuumRevivedCoreChecks by ticket P1.1 with the
// assertions unchanged. These are the DETERMINISTIC tests (mapping totality,
// label/glyph presence, WCAG contrast, distinctness). Pixel appearance is a
// separate Layer-2 vision-QA gate in the Component Lab, not tested here.
//
// The contrast assertion is the deterministic guard for the exact bug we hit
// in the managed-agent tile: black text on a dark-blue fill. It is encoded
// below both as a live invariant (every chip pair ≥ 4.5:1) and as a
// regression witness (the original bad pairing must FAIL the metric).
func runStatusChipChecks() {
    // 1. Totality — every status maps; no default hole, no empty content.
    for status in AgentStatus.allCases {
        let d = StatusChipPresenter.display(for: status)
        expect(!d.label.isEmpty, "StatusChip: \(status.rawValue) has a non-empty label")
        expect(!d.glyph.isEmpty, "StatusChip: \(status.rawValue) has a non-empty glyph")
    }

    // 2. Contrast — every chip owns its fg/bg and the pair meets WCAG AA (4.5:1).
    for status in AgentStatus.allCases {
        let d = StatusChipPresenter.display(for: status)
        let ratio = WCAGContrast.ratio(d.foreground, d.background)
        expect(ratio >= 4.5,
               "StatusChip: \(status.rawValue) fg/bg contrast \(String(format: "%.2f", ratio)):1 must be ≥ 4.5:1")
    }

    // 3. Distinctness — no two statuses share a background (they must read apart).
    var seenBackgrounds: [String: AgentStatus] = [:]
    for status in AgentStatus.allCases {
        let key = StatusChipPresenter.display(for: status).background.hexKey
        expect(seenBackgrounds[key] == nil,
               "StatusChip: \(status.rawValue) background collides with \(seenBackgrounds[key]?.rawValue ?? "?")")
        seenBackgrounds[key] = status
    }

    // 4. Metric anchor — frame the ratio so a broken WCAGContrast.ratio() can't
    //    make (2) vacuously pass, and pin the original bug as a regression witness.
    let white = ChipColor(r: 1, g: 1, b: 1)
    let black = ChipColor(r: 0, g: 0, b: 0)
    let wb = WCAGContrast.ratio(white, black)
    expect(wb >= 20.9 && wb <= 21.1, "StatusChip: white/black contrast must be ~21:1 (got \(String(format: "%.2f", wb)))")
    let tileDarkBlue = ChipColor(r: 0.11, g: 0.13, b: 0.16)  // the managed-tile fill from the bug
    expect(WCAGContrast.ratio(black, tileDarkBlue) < 4.5,
           "StatusChip: the original bug pairing (black on dark blue) must FAIL the metric")

    print("StatusChip checks passed: \(AgentStatus.allCases.count) statuses map with labels+glyphs, all fg/bg pairs ≥ 4.5:1, backgrounds distinct, metric anchored (white/black \(String(format: "%.1f", wb)):1, bug pairing correctly fails)")
}
