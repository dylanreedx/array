import AppKit

/// Every transcript tick re-applies the compact status row. An identical request
/// at the same width must repaint nothing, and any change it paints — the
/// presentation, the last prompt, background jobs or the width — must repaint.
@MainActor
func runCompactStatusRowSkipChecks() throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    let base = AgentCompactStatusPresentation(
        location: .init(symbolName: "house", text: "project root",
                        accessibilityLabel: "Home and Where: project root.", detailText: "project root", isExternal: false),
        activity: .silent(detailText: "Activity phase: idle."),
        context: AgentRadialContextMeterPresentation(
            state: .known, fraction: 0.40, label: "40%", accessibilityLabel: "Context window 40 percent used.",
            detailText: "40 percent used", warningMarker: nil),
        quotas: [], cost: nil, account: nil,
        enabledElements: [.location, .activity, .contextMeter])
    let row = AgentCompactStatusRowView()
    row.frame = NSRect(x: 0, y: 0, width: 420, height: AgentCompactStatusRowView.preferredHeight)
    row.apply(base)
    row.layoutSubtreeIfNeeded()
    var applies = row.qaFullApplyCount
    try expect(applies >= 1, "the first apply must paint the row")

    func step(_ label: String, repaints: Bool, _ action: () -> Void) throws {
        action()
        let now = row.qaFullApplyCount
        try expect((now > applies) == repaints,
                   "\(label): expected \(repaints ? "a repaint" : "no repaint"), full applies \(applies) -> \(now)")
        applies = now
    }

    try step("identical presentation", repaints: false) { row.apply(base) }
    try step("identical presentation again", repaints: false) { row.apply(base) }

    let busier = AgentCompactStatusPresentation(
        location: base.location, activity: base.activity,
        context: AgentRadialContextMeterPresentation(
            state: .known, fraction: 0.55, label: "55%", accessibilityLabel: "Context window 55 percent used.",
            detailText: "55 percent used", warningMarker: nil),
        quotas: [], cost: nil, account: nil, enabledElements: base.enabledElements)
    try step("changed context", repaints: true) { row.apply(busier) }
    try expect(row.qaContextText.contains("55"), "the changed context must reach the label; got \(row.qaContextText)")
    try step("identical after change", repaints: false) { row.apply(busier) }

    try step("changed last prompt", repaints: true) { row.applyLastPrompt("Sam sent the last prompt · 10:52") }
    try step("same last prompt", repaints: false) { row.applyLastPrompt("Sam sent the last prompt · 10:52") }

    try step("background jobs appear", repaints: true) {
        row.applyBackgroundJobs(value: "1 job", detail: "npm run dev :3000", spoken: "One background job.")
    }
    try step("identical presentation with jobs", repaints: false) { row.apply(busier) }

    try step("width moved a quarter point", repaints: true) {
        row.setFrameSize(NSSize(width: 420.25, height: row.frame.height))
        row.apply(busier)
    }
    try step("identical at the new width", repaints: false) { row.apply(busier) }
}
