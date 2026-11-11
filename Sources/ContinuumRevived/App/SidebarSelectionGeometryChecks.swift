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
        func sheets(_ view: NSView) -> [InboxGroupBackgroundView] {
            ((view as? InboxGroupBackgroundView).map { [$0] } ?? []) + view.subviews.flatMap(sheets)
        }
        func checkBottom(_ inbox: AgentInboxView, lead: UUID, helpers: [AgentInboxRow]) throws {
            let visible = helpers.compactMap { inbox.cellForQA(id: $0.id) }
            guard let last = helpers.first(where: {
                inbox.ownershipSliceForQA(id: $0.id)?.continuesBelow == false
                    && inbox.cellForQA(id: $0.id) != nil
            }), let cell = inbox.cellForQA(id: last.id),
                  let slice = inbox.ownershipSliceForQA(id: last.id),
                  let leadCell = inbox.cellForQA(id: lead) else { return }
            let actualHeight = leadCell.bounds.height + visible.reduce(0) { $0 + $1.bounds.height }
                + CGFloat(visible.count) * CGFloat(AgentInboxView.rowSpacing)
            guard abs(slice.groupHeight - actualHeight) < 0.5 else {
                throw Failure(message: "group height is stale after live helper changes")
            }
            guard let sheet = sheets(cell).first, let strip = sheet.ownershipStrip,
                  strip.roundsBottom, sheet.bounds.contains(strip.rect) else {
                throw Failure(message: "group bottom corners are clipped")
            }
            let title = sheet.convert(cell.qaTitleFrameForQA, from: cell)
            guard strip.rect.maxY - title.maxY >= InboxOwnershipChrome.footPad - 0.5 else {
                throw Failure(message: "last helper has no group bottom padding")
            }
            if let light = lights(cell).first, !light.isHidden,
               let surface = light.layer?.sublayers?.first {
                let bottomCorners = CGRect(x: surface.frame.minX,
                    y: surface.frame.maxY - surface.cornerRadius,
                    width: surface.frame.width, height: surface.cornerRadius)
                guard surface.cornerRadius > 0, light.bounds.contains(bottomCorners) else {
                    throw Failure(message: "group light clips its bottom corners")
                }
            }
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
                var previousHelpers: Set<UUID> = []
                for (transition, count) in [0, 1, 2, 1, 0, 2].enumerated() {
                    let next = [parent] + Array(helpers.prefix(count))
                    let currentHelpers = Set(helpers.prefix(count).map(\.id))
                    if transition == 0 {
                        inbox.reload(rows: next)
                    } else {
                        inbox.apply(rows: next, changed: AgentsBoardChangeSet(
                            added: currentHelpers.subtracting(previousHelpers),
                            updated: [lead], removed: previousHelpers.subtracting(currentHelpers)))
                    }
                    previousHelpers = currentHelpers
                    inbox.layoutViewportForQA()
                    try checkBottom(inbox, lead: lead, helpers: helpers)
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
                            try checkBottom(inbox, lead: lead, helpers: helpers)
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
        print("SidebarSelectionGeometryChecks passed: live 0→1→2→1→0→2 helpers, group height, bottom padding/corners, both appearances, all four styles, 24 fold samples and settling per transition")
    }
}
