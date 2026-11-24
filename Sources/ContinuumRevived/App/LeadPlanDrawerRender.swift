import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--lead-plan-drawer-render <dir>`: draws the plan drawer from fixtures (Dylan's
/// 0.7.60 drawer, the same with a fresh failure and a decision, and a small
/// plan), resting and open, light and dark, at 1x and 2x. Also measures how far
/// each dot sits from the centre of the capitals beside it.
@MainActor
enum LeadPlanDrawerRender {
    static let width: CGFloat = 620
    static let day: TimeInterval = 86400

    static func helper(_ name: String, _ model: String, _ phase: LeadPlanDrawerModel.Phase, ago: TimeInterval? = nil, stale: Bool = false) -> LeadPlanDrawerModel.Helper {
        .init(id: AgentID(rawValue: UUID()), name: name, model: model, phase: phase, endedAgo: ago, stale: stale)
    }

    /// His drawer: three failures 5–6 days old, two idle helpers, one done an
    /// hour ago, and a five-step plan written two minutes ago.
    static func his(fresh: Bool = false, collapsed: Bool) -> LeadPlanDrawerModel {
        let strays = [
            helper("Sidebar fold band", "Sonnet 5.5", .failed, ago: 6 * day, stale: true),
            helper("Relay deletion routes", "Opus 5.5", .failed, ago: 6 * day, stale: true),
            helper("Bubble orb sizing", "Sonnet 5.5", .failed, ago: 5 * day, stale: true),
            helper("Settings theme picker", "Opus 5.5", .idle),
            helper("Companion task alerts", "Sonnet 5.5", .idle),
            helper("iOS preview tiles", "Sonnet 5.5", .done, ago: 3600),
        ]
        let steps: [LeadPlanDrawerModel.Step] = [
            .init(title: "Fix the drawer's data model", owner: .helpers([helper("Drawer data model", "Sonnet 5.5", .working)])),
            .init(title: "Design three drawer directions",
                  owner: .helpers([fresh ? helper("Drawer redesign view", "Sonnet 5.5", .failed, ago: 12 * 60)
                                         : helper("Drawer redesign view", "Sonnet 5.5", .idle)])),
            .init(title: "Review the directions with Dylan", owner: .lead),
            .init(title: "Join the view to the model", owner: .lead),
            .init(title: "Gate and ship 0.7.61", owner: .lead),
        ]
        return .init(steps: steps, strays: strays,
                     decision: fresh ? "Ship the drawer fix in 0.7.61, or hold it?" : nil,
                     options: fresh ? ["Ship it", "Hold for 0.7.62"] : [], collapsed: collapsed)
    }

    static func small(collapsed: Bool) -> LeadPlanDrawerModel {
        .init(steps: [
            .init(title: "Fix the login redirect", owner: .helpers([helper("Login redirect fix", "Sonnet 5.5", .working)])),
            .init(title: "Ship the hotfix", owner: .lead),
        ], collapsed: collapsed)
    }

    struct Shot { let name: String; let label: String; let image: NSBitmapImageRep; let height: CGFloat }

    static func shot(appearance: NSAppearance,
                     fill: (AgentLeadPlanView) -> Void) -> (NSBitmapImageRep, CGFloat, AgentLeadPlanView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = host
        let view = AgentLeadPlanView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(view)
        fill(view)
        let height = view.intrinsicContentSize.height
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return (rep, height, view, window)
    }

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var summary: [String] = []
        for (appearanceName, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: appearanceName)!
            NSApp.appearance = appearance
            var shots: [Shot] = []
            for c in [true, false] {
                let s = c ? "resting" : "open"
                let cases: [(String, String, LeadPlanDrawerModel)] = [
                    ("his-\(s)", "His drawer · \(s)", his(collapsed: c)),
                    ("attention-\(s)", "His drawer + a fresh failure and a decision · \(s)", his(fresh: true, collapsed: c)),
                    ("small-\(s)", "Small: 2 steps, 1 helper · \(s)", small(collapsed: c))]
                for (name, label, model) in cases {
                    let (rep, height, _, _) = shot(appearance: appearance) { $0.qaShowDrawer(model) }
                    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("checklist-\(name)-\(tag).png"))
                    shots.append(Shot(name: name, label: label, image: rep, height: height))
                    if tag == "light" { summary.append("checklist \(name): \(Int(height)) pt") }
                }
            }
            try sheet(shots, title: "Checklist — the plan is the list", appearance: appearance)
                .write(to: directory.appendingPathComponent("sheet-checklist-\(tag).png"))
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        summary += alignment()
        let text = summary.joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent("heights.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    /// One PNG per direction: each case under a caption, on the canvas colour.
    static func sheet(_ shots: [Shot], title: String, appearance: NSAppearance) throws -> Data {
        let pad: CGFloat = 24, caption: CGFloat = 22
        let total = pad + 30 + shots.reduce(0) { $0 + caption + $1.height + pad }
        let size = NSSize(width: width + pad * 2, height: total)
        let image = NSImage(size: size, flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance {
                SurfaceToken.canvas.color.nsColor(for: appearance.tokenTheme).setFill()
                NSRect(origin: .zero, size: size).fill()
                let ink = TextToken.textPrimary.color.nsColor(for: appearance.tokenTheme)
                let muted = TextToken.textSecondary.color.nsColor(for: appearance.tokenTheme)
                (title as NSString).draw(at: NSPoint(x: pad, y: pad), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: ink])
                var y = pad + 30
                for shot in shots {
                    ("\(shot.label) — \(Int(shot.height)) pt" as NSString).draw(at: NSPoint(x: pad, y: y + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted])
                    y += caption
                    let rect = NSRect(x: pad, y: y, width: width, height: shot.height)
                    shot.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    LineToken.border.color.nsColor(for: appearance.tokenTheme).setStroke()
                    NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)).stroke()
                    y += shot.height + pad
                }
            }
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation(using: .none, factor: 2)!)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// Vertical distance, in points, between a dot's centre and the centre of
    /// the capitals on its line ("HIH"), measured from pixels.
    static func alignment() -> [String] {
        let appearance = NSAppearance(named: .aqua)!
        func inkRows(_ rep: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> (Int, Int)? {
            guard let bg = rep.colorAt(x: 1, y: yRange.lowerBound + 1)?.usingColorSpace(.sRGB) else { return nil }
            var lo: Int?, hi: Int?
            for y in yRange { for x in xRange {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent) > 0.45 {
                    lo = min(lo ?? y, y); hi = max(hi ?? y, y)
                }
            } }
            guard let lo, let hi else { return nil }
            return (lo, hi)
        }
        var out: [String] = []
        do {
            let m = LeadPlanDrawerModel(steps: [.init(title: "HIH", owner: .helpers([helper("HIH", "HIH", .working)]))], collapsed: false)
            let (rep, _, view, _) = shot(appearance: appearance) { $0.qaShowDrawer(m) }
            guard let layout = view.drawerLayout, !layout.rows.isEmpty else { return out }
            let s = CGFloat(rep.pixelsWide) / view.bounds.width
            let row = view.drawerRowRect(0, in: layout)
            let rows = Int(row.minY * s)..<Int(row.maxY * s)
            let titleX = 16 + 14 + layout.leadColumn
            if let dot = inkRows(rep, xRange: Int(14 * s)..<Int(23 * s), yRange: rows),
               let caps = inkRows(rep, xRange: Int(titleX * s)..<Int((titleX + 24) * s), yRange: rows) {
                out.append(String(format: "alignment checklist: dot centre %.1f pt below cap centre", (Double(dot.0 + dot.1) - Double(caps.0 + caps.1)) / 2 / Double(s)))
            }
        }
        return out
    }
}
