import AppKit
import ContinuumRevivedAgentUI

/// Prototype witness for the plan-drawer proposal: renders the PRODUCTION
/// `AgentLeadPlanView` (not a mock) for a baseline and three directions,
/// light and dark, into `CONTINUUM_PLAN_DRAWER_DIR`.
@MainActor
enum PlanDrawerStills {
    typealias P = LeadPlanPresentation
    typealias S = LeadPlanPresentation.Step

    // Replay of the release lead's drawer three days after it was last written.
    static let baseline = P(steps: [
        S(title: "0.7.54: fix 3 review blockers", owner: "Iris · GPT-6.2-Sol", state: .done),
        S(title: "0.7.54: combined preview build", owner: "Noor · Sonnet 5.5", state: .done),
        S(title: "Dylan picks option, then build for 0.7.55", owner: "You", state: .needsYou),
        S(title: "0.7.55: perf and nav fixes", owner: "helper A", state: .waiting),
        S(title: "Full gate and ship", owner: "Lead", state: .waiting),
    ], collapsed: false)

    // A: same plan, but the drawer admits it is old and says what moved on.
    static let stale = P(steps: [
        S(title: "0.7.54: fix 3 review blockers", owner: "Iris · GPT-6.2-Sol", state: .done, note: "3d ago"),
        S(title: "0.7.54: combined preview build", owner: "Noor · Sonnet 5.5", state: .done, note: "3d ago"),
        S(title: "Dylan picks option, then build for 0.7.55", owner: "You", state: .needsYou, note: "asked 3d ago"),
        S(title: "0.7.55: perf and nav fixes", owner: "helper A", state: .waiting, note: "never started"),
        S(title: "Full gate and ship", owner: "Lead", state: .waiting),
    ], collapsed: false, banner: "Plan last updated 3 days ago · the lead has run 12 helpers since", dimmed: true)

    // B: no plan to maintain. The drawer is the lead's real helpers, live.
    static let roster = P(steps: [
        S(title: "Needs you", owner: "", state: .waiting, isSection: true),
        S(title: "Pick the 0.7.57 candidate", owner: "Release lead", state: .needsYou, note: "2 options", liveDot: true),
        S(title: "Working", owner: "", state: .waiting, isSection: true),
        S(title: "Profiler implementation", owner: "Maya · Sonnet 5.5", state: .running, note: "14 min", liveDot: true),
        S(title: "Done today", owner: "", state: .waiting, isSection: true),
        S(title: "Perf leftovers measurement", owner: "Leo · Sonnet 5.5", state: .done, note: "2h ago", liveDot: true),
        S(title: "Stabilize frame uptime", owner: "Ana · Sonnet 5.5", state: .failed, note: "1 check red", liveDot: true),
    ], collapsed: false)

    // C: decision surfaced in the drawer, only when the lead has one for Dylan.
    static let decision = P(steps: [
        S(title: "Ship 0.7.55 perf fixes", owner: "Iris · GPT-6.2-Sol", state: .done, liveDot: true),
        S(title: "Choose the 0.7.57 candidate", owner: "You", state: .needsYou, note: "now", liveDot: true),
        S(title: "Build and gate", owner: "Lead", state: .waiting),
    ], collapsed: false, banner: "Decision: which change leads 0.7.57?",
       chips: ["Perf leftovers", "Sidebar polish", "Neither, hold"])

    static func run() throws {
        guard let dir = ProcessInfo.processInfo.environment["CONTINUUM_PLAN_DRAWER_DIR"] else {
            throw NSError(domain: "plan-drawer", code: 1, userInfo: [NSLocalizedDescriptionKey: "CONTINUUM_PLAN_DRAWER_DIR not set"])
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        let variants: [(String, P)] = [("0-today", baseline), ("1-stale-aware", stale), ("2-live-roster", roster), ("3-decision", decision)]
        for (appName, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let theme = NSAppearance(named: name)!
            NSApp.appearance = theme
            for (label, value) in variants {
                let view = AgentLeadPlanView(frame: .zero)
                view.appearance = theme
                view.update(value)
                let h = view.intrinsicContentSize.height
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: h), styleMask: [.borderless], backing: .buffered, defer: true)
                window.appearance = theme
                view.translatesAutoresizingMaskIntoConstraints = true
                view.frame = NSRect(x: 0, y: 0, width: 760, height: h)
                window.contentView?.addSubview(view)
                view.layoutSubtreeIfNeeded()
                var result: Result<NSBitmapImageRep, Error>!
                theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: view, id: "plan-drawer") } }
                try result.get().representation(using: .png, properties: [:])!
                    .write(to: out.appendingPathComponent("\(label)-\(appName).png"))
            }
        }
    }
}
