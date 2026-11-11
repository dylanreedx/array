import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

@MainActor
enum SidebarSelectionGeometryChecks {
    struct Failure: Error { let message: String }
    static func run() throws {
        func lights(_ view: NSView) -> [InboxExpandedGroupLight] {
            ((view as? InboxExpandedGroupLight).map { [$0] } ?? []) + view.subviews.flatMap(lights)
        }
        func cards(_ view: NSView) -> [AgentInboxCardView] {
            ((view as? AgentInboxCardView).map { [$0] } ?? []) + view.subviews.flatMap(cards)
        }
        for dark in [false, true] {
            for style in SidebarActiveIndicatorStyle.allCases {
                let suite = "array.selection-geometry.\(UUID())"
                let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(style.rawValue, forKey: SidebarActiveIndicatorStyle.defaultsKey)
                let lead = UUID()
                let parent = AgentInboxRow(
                    id: lead, title: "Selected lead gaining helpers", projectName: "Array",
                    state: .working, branch: "array/integration", createdAt: Date())
                let helpers = (0..<2).map { AgentInboxRow(id: UUID(), title: "Helper \($0)", state: .working, depth: 1, createdAt: Date(), parentId: lead) }
                let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 380, height: 700), indicatorDefaults: defaults)
                inbox.openAgentId = lead
                let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = inbox
                window.orderFrontOffscreenForChecks()
                defer { window.orderOut(nil) }
                for (transition, count) in [0, 2, 0, 2].enumerated() {
                    let next = [parent] + (count == 0 ? [] : helpers)
                    if transition == 0 {
                        inbox.reload(rows: next)
                    } else {
                        inbox.apply(rows: next, changed: AgentsBoardChangeSet(
                            added: count == 2 ? Set(helpers.map(\.id)) : [],
                            updated: [lead], removed: count == 0 ? Set(helpers.map(\.id)) : []))
                    }
                    inbox.layoutViewportForQA()
                    if count == 0 {
                        guard let cell = inbox.cellForQA(id: lead), let card = cards(cell).first,
                              card.layer?.cornerRadius ?? 0 > 0 else {
                            throw Failure(message: "singleton lost its rounded selection surface")
                        }
                        if style != .classic {
                            guard !card.qaIndicatorLayers.wash.isHidden,
                                  abs(card.qaIndicatorLayers.wash.bounds.height - cell.qaCardFrameForQA.height) < 0.5 else {
                                throw Failure(message: "removing helpers left a stale selection height")
                            }
                        }
                        continue
                    }
                    for _ in 0..<2 {
                        guard let cell = inbox.cellForQA(id: lead), let light = lights(cell).first else { throw Failure(message: "missing lead light") }
                        if style != .classic && !light.isHidden {
                            let card = cell.qaCardFrameForQA
                            guard let surface = light.layer?.sublayers?.first,
                                  abs(surface.frame.height - card.height) < 0.5,
                                  light.bounds.contains(surface.frame), surface.cornerRadius > 0,
                                  surface.sublayers?.contains(where: { ($0 as? CAShapeLayer)?.strokeColor != nil }) == true else {
                                throw Failure(message: "\(style)/dark-\(dark): expanded lead selection loses its complete rounded surface or even outline")
                            }
                        }
                        let selectedCard = cell.convert(cell.qaCardFrameForQA, to: inbox)
                        for helper in helpers {
                            if let helperCell = inbox.cellForQA(id: helper.id),
                               selectedCard.intersects(helperCell.convert(helperCell.bounds, to: inbox)) {
                                throw Failure(message: "helper paint overlaps the lead selection corners")
                            }
                        }
                        if !light.isHidden, let surface = light.layer?.sublayers?.first {
                            var ancestor = light.superview
                            while let owner = ancestor, owner !== inbox {
                                let fullSurface = owner.convert(surface.frame, from: light)
                                if owner.clipsToBounds && !owner.bounds.insetBy(dx: -0.5, dy: -0.5).contains(fullSurface) {
                                    throw Failure(message: "lead selection clipped by \(type(of: owner))")
                                }
                                ancestor = owner.superview
                            }
                        }
                        inbox.toggleCollapse(parentId: lead)
                        inbox.layoutViewportForQA()
                        for _ in 0..<24 {
                            inbox.foldMotionForQA.advance(by: 1.0 / 120)
                            guard let sampled = inbox.cellForQA(id: lead), let light = lights(sampled).first else { throw Failure(message: "missing sampled lead") }
                            if !light.isHidden {
                                guard let surface = light.layer?.sublayers?.first,
                                      light.bounds.contains(surface.frame),
                                      abs(surface.frame.height - sampled.qaCardFrameForQA.height) < 0.5,
                                      surface.cornerRadius > 0,
                                      surface.sublayers?.contains(where: { ($0 as? CAShapeLayer)?.strokeColor != nil }) == true else {
                                    throw Failure(message: "selection corners or outline clipped during fold")
                                }
                            }
                        }
                    }
                    let output = URL(fileURLWithPath: "qa-runs/sidebar-selection-geometry", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    if let bitmap = SettingsFixtureWindow.capture(inbox),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: output.appendingPathComponent("\(style.rawValue)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
        print("SidebarSelectionGeometryChecks passed: live 0→2→0→2 helpers, both appearances, all four styles, 24 fold samples and settling per transition")
    }
}
