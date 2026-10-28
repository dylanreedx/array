import AppKit
import ContinuumRevivedAgentUI
import Foundation

/// Native review sheet and outcome witness. All variants use the actual sidebar
/// and its cards; no duplicate drawing implementation or user-facing setting.
@MainActor
enum SidebarWorkspaceTreatmentChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(outputDirectory: URL) async throws -> String {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
        let personal = SidebarIconAlignmentChecks.id(700)
        let work = SidebarIconAlignmentChecks.id(701)
        func row(_ n: Int, _ title: String, workspace: UUID, identity: String? = nil,
                 parent: UUID? = nil, lifecycle: InboxLifecycle = .active,
                 state: InboxState = .ready) -> AgentInboxRow {
            AgentInboxRow(id: SidebarIconAlignmentChecks.id(n), title: title,
                projectName: workspace == personal ? "Array" : "harmony",
                workspaceName: workspace == personal ? "personal" : "work", workspaceId: workspace,
                state: state, lifecycle: lifecycle, model: "gpt-6.1-sol", branch: "array/integration",
                depth: parent == nil ? 0 : 1, createdAt: now.addingTimeInterval(-600),
                parentId: parent, identityColor: identity)
        }
        let fixtures = [
            row(710, "Refine sidebar interactions", workspace: personal, identity: "blue"),
            row(711, "Review remaining local work", workspace: work, state: .working),
            row(712, "Check the metadata alignment", workspace: work, parent: SidebarIconAlignmentChecks.id(711)),
            row(714, "Review child spacing", workspace: work, parent: SidebarIconAlignmentChecks.id(711)),
            row(715, "Verify row hit targets", workspace: work, parent: SidebarIconAlignmentChecks.id(711)),
            row(713, "Plan richer file previews", workspace: personal, identity: "teal", lifecycle: .settled(at: now.addingTimeInterval(-120))),
        ]
        let priorAppearance = NSApp.appearance
        defer { NSApp.appearance = priorAppearance }
        var captures: [(NSBitmapImageRep, String)] = []
        var imageNames: [String] = []
        var restImages: Set<Data> = []
        var contrastMeasurements = 0
        var worstContrast = Double.infinity
        var badgeMeasurements = 0
        var worstBadgeDelta: CGFloat = 0
        // Deliberately unequal transparent margins on both axes. This fails
        // when a badge centres the NSImageView box instead of visible pixels.
        let paddedFavicon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 15, width: 12, height: 8), xRadius: 2, yRadius: 2).fill()
            return true
        }
        func chip(_ colour: NSColor) throws -> ChipColor {
            guard let rgb = colour.usingColorSpace(.sRGB) else { throw Failure(description: "non-sRGB workspace text") }
            return ChipColor(r: rgb.redComponent, g: rgb.greenComponent, b: rgb.blueComponent)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            for treatment in AgentInbox96CellView.WorkspaceTreatment.allCases {
                let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 340, height: 440))
                inbox.clock = { now }
                inbox.prefersReducedMotion = { true }
                inbox.foldsUntouchedGroups = true
                inbox.hoverCardEnabled = false
                inbox.onRowAction = { _, _ in }
                inbox.wiredRowActions = [.settle, .snooze]
                inbox.workspaceColourNames = [personal: "teal", work: "purple"]
                let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = inbox
                window.orderFrontOffscreenForChecks()
                defer { window.orderOut(nil) }
                inbox.reload(rows: fixtures)
                _ = inbox.pickScopeForQA(.all)
                inbox.expandHistoryShelfForQA()
                inbox.layoutForQA()
                func cards(_ view: NSView) -> [AgentInbox96CellView] {
                    (view as? AgentInbox96CellView).map { [$0] } ?? view.subviews.flatMap(cards)
                }
                var originalProjectIcon: NSImage?
                func configure() throws {
                    let visible = cards(inbox)
                    guard !visible.isEmpty else { throw Failure(description: "workspace treatments: no production cards") }
                    for card in visible {
                        card.workspaceTreatmentForQA = treatment
                        card.reducesHoverMotion = { true }
                        if card.qaAgentID == fixtures[1].id {
                            if originalProjectIcon == nil { originalProjectIcon = card.qaProjectIconImageForQA }
                            card.setProjectIcon(paddedFavicon, for: fixtures[1].id)
                        }
                        card.layoutSubtreeIfNeeded()
                        guard card.qaWorkspaceTreatmentIsInsideCard else {
                            throw Failure(description: "\(treatment.rawValue): workspace decoration escapes card")
                        }
                    }
                }
                for state in ["rest", "hover", "selected"] {
                    if state == "hover" { _ = inbox.hoverRowForQA(id: fixtures[0].id) }
                    if state == "selected" {
                        _ = inbox.hoverRowForQA(id: nil)
                        _ = inbox.selectRowForQA(id: fixtures[0].id)
                        inbox.rebuildRowsForQA()
                    }
                    inbox.layoutForQA()
                    try configure()
                    guard let dot = inbox.identityDotForQA(agentId: fixtures[0].id), dot.dot != nil else {
                        throw Failure(description: "workspace treatments must preserve existing agent identity dot")
                    }
                    if treatment == .workspaceLabel {
                        guard cards(inbox).contains(where: { $0.qaWorkspaceLabel == "personal" }) else {
                            throw Failure(description: "workspace label must display actual workspace name")
                        }
                    }
                    if treatment == .iconBadge {
                        for id in [fixtures[0].id, fixtures[1].id] {
                            guard let card = cards(inbox).first(where: { $0.qaAgentID == id }),
                                  let geometry = card.qaWorkspaceIconBadgeGeometry else {
                                throw Failure(description: "selected icon treatment must draw folder and padded favicon containers")
                            }
                            let dx = abs(geometry.ink.midX - geometry.badge.midX)
                            let dy = abs(geometry.ink.midY - geometry.badge.midY)
                            let lineDelta = abs(geometry.badge.midY - geometry.textCentre)
                            worstBadgeDelta = max(worstBadgeDelta, dx, dy, lineDelta)
                            guard dx <= 0.5, dy <= 0.5, lineDelta <= 0.5,
                                  geometry.badge.insetBy(dx: 2.5, dy: 2.5).contains(geometry.ink),
                                  abs(geometry.textGap - 4) <= 0.5, geometry.statusClear else {
                                throw Failure(description: "icon container alignment: dx=\(dx), dy=\(dy), text line=\(lineDelta), gap=\(geometry.textGap), status clear=\(geometry.statusClear)")
                            }
                            badgeMeasurements += 1
                        }
                    }
                    await Task.yield()
                    inbox.displayIfNeeded()
                    guard let rep = inbox.bitmapImageRepForCachingDisplay(in: inbox.bounds) else {
                        throw Failure(description: "workspace treatments could not allocate native capture")
                    }
                    inbox.cacheDisplay(in: inbox.bounds, to: rep)
                    // Measure the configured text ink against pixels captured
                    // immediately beside it inside its actual badge/card surface.
                    for card in cards(inbox) {
                        guard let label = card.qaWorkspaceTextForQA,
                              let foreground = label.textColor else { continue }
                        let point = label.convert(NSPoint(x: 0.5, y: label.bounds.midY), to: inbox)
                        let scale = CGFloat(rep.pixelsWide) / inbox.bounds.width
                        let pixelY = inbox.isFlipped ? point.y : inbox.bounds.height - point.y
                        let px = Int(point.x * scale), py = Int(pixelY * scale)
                        guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                              let background = rep.colorAt(x: px, y: py) else {
                            throw Failure(description: "workspace text contrast sample outside capture")
                        }
                        let bg = try chip(background)
                        let ink = try chip(foreground).composited(over: bg, alpha: Double(label.alphaValue))
                        let ratio = WCAGContrast.ratio(ink, bg)
                        worstContrast = min(worstContrast, ratio)
                        contrastMeasurements += 1
                        guard ratio >= DesignTokens.textFloor else {
                            throw Failure(description: "\(treatment.rawValue) \(appearance.rawValue) \(state): workspace text contrast \(ratio):1 below 4.5:1")
                        }
                    }
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        throw Failure(description: "workspace treatments could not encode native capture")
                    }
                    let name = "\(treatment.rawValue)-\(appearance == .aqua ? "light" : "dark")-\(state).png"
                    try png.write(to: outputDirectory.appendingPathComponent(name))
                    if treatment == .iconBadge {
                        let selectedName = "selected-icon-\(appearance == .aqua ? "light" : "dark")-\(state).png"
                        // User-facing captures show the real folder fallback.
                        // The deliberately padded test icon remains in the
                        // measured evidence above and the variant captures.
                        for card in cards(inbox) where card.qaAgentID == fixtures[1].id {
                            card.setProjectIcon(originalProjectIcon, for: fixtures[1].id)
                        }
                        inbox.layoutForQA()
                        inbox.displayIfNeeded()
                        guard let selected = inbox.bitmapImageRepForCachingDisplay(in: inbox.bounds) else {
                            throw Failure(description: "selected project-icon preview could not allocate capture")
                        }
                        inbox.cacheDisplay(in: inbox.bounds, to: selected)
                        guard let selectedPNG = selected.representation(using: .png, properties: [:]) else {
                            throw Failure(description: "selected project-icon preview could not encode capture")
                        }
                        try selectedPNG.write(to: outputDirectory.appendingPathComponent(selectedName))
                    }
                    imageNames.append(name)
                    captures.append((rep, name))
                    if state == "rest" { restImages.insert(png) }
                }
                inbox.reload(rows: fixtures.filter { $0.workspaceId == personal })
                inbox.layoutForQA()
                guard cards(inbox).allSatisfy({ $0.workspaceMarkColour == nil }) else {
                    throw Failure(description: "single-workspace sidebar must hide redundant workspace decoration")
                }
            }
        }
        guard badgeMeasurements == 12 else { throw Failure(description: "icon container witness missed folder/favicon interaction appearances") }
        guard contrastMeasurements >= 12 else { throw Failure(description: "workspace text contrast witness missed light/dark interaction states") }
        guard restImages.count == 10 else { throw Failure(description: "five treatments × two appearances must render distinctly") }
        // Contact sheet groups appearances by rows, treatments by columns; each
        // cell contains the same production sidebar in rest/hover/selected states.
        let cell = NSSize(width: 340, height: 460)
        let sheet = NSImage(size: NSSize(width: cell.width * 5, height: cell.height * 6), flipped: true) { _ in
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: cell.width * 5, height: cell.height * 6).fill()
            for (index, capture) in captures.enumerated() {
                let theme = index / 15, option = (index % 15) / 3, state = index % 3
                let origin = NSPoint(x: CGFloat(option) * cell.width, y: CGFloat(theme * 3 + state) * cell.height)
                (capture.1 as NSString).draw(at: origin, withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
                NSImage(cgImage: capture.0.cgImage!, size: NSSize(width: 340, height: 440))
                    .draw(in: NSRect(x: origin.x, y: origin.y + 20, width: 340, height: 440))
            }
            return true
        }
        guard let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure(description: "workspace treatments contact sheet failed")
        }
        try png.write(to: outputDirectory.appendingPathComponent("options.png"))
        let manifest = ["images": imageNames, "default": ["iconBadge"], "states": ["rest", "hover", "selected"]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("manifest.json"))
        return "sidebar-workspace-treatment: five native no-dot treatments in light/dark × rest/hover/selected; workspace marks stay inside cards, actual workspace names, original agent identity dots preserved, single-workspace marks hidden; \(contrastMeasurements) native workspace text contrast pairs ≥4.5:1 (worst \(String(format: "%.2f", worstContrast)):1); \(badgeMeasurements) rendered folder/padded-favicon container alignments (worst \(String(format: "%.2f", worstBadgeDelta))pt), selected-icon-* previews; 30 captures + options.png at \(outputDirectory.path)"
    }
}
