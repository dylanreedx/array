import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

@MainActor
enum SidebarIndicatorTruthTableChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }
    static func run() throws {
        var failures: [String] = []
        var passed = 0
        var total = 0
        for dark in [false, true] {
            for style in SidebarActiveIndicatorStyle.allCases {
                for scope in ["selected", "working"] {
                    let suite = "array.indicator-truth.\(UUID())"
                    let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
                    defaults.set(style.rawValue, forKey: SidebarActiveIndicatorStyle.defaultsKey)
                    defaults.set(scope, forKey: SidebarActiveIndicatorScope.defaultsKey)
                    let lead = UUID(), helper = UUID(), arrival = UUID()
                    let now = Date()
                    let inbox = AgentInboxView(frame: NSRect(x: 0,y: 0,width: 380,height: 600), indicatorDefaults: defaults)
                    inbox.foldsUntouchedGroups = false
                    inbox.prefersReducedMotion = { false }
                    let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = inbox
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.orderFrontOffscreenForChecks()
                    for selection in ["lead", "helper", "none"] {
                        // "helper": an idle lead whose helper works — the group still works.
                        for work in ["none", "both", "helper"] {
                            let working = work != "none"
                            for fold in ["collapsed", "expanded", "mid-fold", "live-add"] {
                                autoreleasepool {
                                    total += 1
                                    let label = "\(style.rawValue)/\(scope)/\(selection)/\(work)/\(fold)/\(dark)"
                                    func row(_ id: UUID, parent: UUID? = nil) -> AgentInboxRow {
                                        let rowWorks = id == lead ? work == "both" : working
                                        return AgentInboxRow(id: id, title: id == lead ? "Selected lead" : "Helper", state: rowWorks ? .working : .ready,
                                            depth: parent == nil ? 0 : 1, createdAt: now, parentId: parent)
                                    }
                                    inbox.foldMotionForQA.cancel()
                                    inbox.openAgentId = nil
                                    inbox.clearSelectionForQA()
                                    inbox.restoreParentFolds([lead: true])
                                    let rows = [row(lead), row(helper, parent: lead)]
                                    inbox.reload(rows: rows)
                                    inbox.openAgentId = selection == "none" ? nil : (selection == "lead" ? lead : helper)
                                    inbox.layoutViewportForQA()
                                    if selection != "none" { _ = inbox.selectRowForQA(id: selection == "lead" ? lead : helper) }
                                    if fold == "expanded" && selection == "helper" {
                                        inbox.toggleCollapse(parentId: lead)
                                        inbox.toggleCollapse(parentId: lead)
                                    }
                                    if fold == "collapsed" || fold == "mid-fold" { inbox.toggleCollapse(parentId: lead) }
                                    if fold == "mid-fold" { inbox.foldMotionForQA.advance(by: 0.025) }
                                    if fold == "live-add" {
                                        inbox.apply(rows: rows + [row(arrival, parent: lead)],
                                            changed: AgentsBoardChangeSet(added: [arrival], updated: [lead], removed: []))
                                    }
                                    inbox.layoutViewportForQA()
                                    let expected = working && (scope == "working" || selection != "none")
                                    let visibleCells = [lead, helper, arrival].compactMap { inbox.cellForQA(id: $0) }
                                    let lights = visibleCells.flatMap { descendants($0, InboxExpandedGroupLight.self) }
                                    let sweeps = visibleCells.flatMap { descendants($0, InboxSweepBorderView.self) }
                                    let cards = visibleCells.flatMap { descendants($0, AgentInboxCardView.self) }
                                    // A group with one visible row draws its style on the card, as 0.7.47 did.
                                    let washes = cards.filter { !$0.qaIndicatorLayers.wash.isHidden && $0.qaIndicatorLayers.wash.superlayer != nil }
                                    let present = style == .classic ? sweeps.contains { !$0.isHidden }
                                        : lights.contains { !$0.isHidden } || !washes.isEmpty
                                    let moving = style == .classic ? sweeps.contains { $0.isMovingForQA } : lights.contains {
                                        !$0.isHidden && $0.renderedLayersForChecks.contains { !($0.animationKeys() ?? []).isEmpty }
                                    } || washes.contains { !($0.qaIndicatorLayers.sheen.animationKeys() ?? []).isEmpty
                                        || !($0.qaIndicatorLayers.wash.animationKeys() ?? []).isEmpty }
                                    // 0.7.47 draws no selection outline on any card, whatever selected it.
                                    let outlines = cards.filter {
                                        !$0.qaIndicatorLayers.edge.isHidden && $0.qaIndicatorLayers.edge.borderWidth > 0
                                    }.count
                                    var correct = present == expected && moving == expected && outlines == 0
                                    // Sheen keeps 0.7.47's faint identity rim; the others stroke nothing.
                                    if style != .classic && style != .sheen {
                                        correct = correct && lights.filter { !$0.isHidden }.allSatisfy {
                                            !$0.renderedLayersForChecks.contains { ($0 as? CAShapeLayer)?.strokeColor != nil }
                                        }
                                    }
                                    correct = correct && cards.allSatisfy { ($0.layer?.cornerRadius ?? 0) > 0 }
                                    if visibleCells.count == 1, let cell = visibleCells.first,
                                       let sheet = descendants(cell, InboxGroupBackgroundView.self).first,
                                       let strip = sheet.ownershipStrip {
                                        correct = correct && strip.roundsTop && strip.roundsBottom && sheet.bounds.contains(strip.rect)
                                    }
                                    let actualHeight = visibleCells.reduce(CGFloat(0)) { $0 + $1.bounds.height }
                                        + CGFloat(max(0, visibleCells.count - 1)) * CGFloat(AgentInboxView.rowSpacing)
                                    for id in [lead, helper, arrival] {
                                        guard let cell = inbox.cellForQA(id: id), let slice = inbox.ownershipSliceForQA(id: id) else { continue }
                                        correct = correct && abs(slice.groupHeight - actualHeight) < 0.5
                                        if id != lead && !slice.continuesBelow {
                                            if let sheet = descendants(cell, InboxGroupBackgroundView.self).first,
                                               let strip = sheet.ownershipStrip {
                                                let title = sheet.convert(cell.qaTitleFrameForQA, from: cell)
                                                correct = correct && strip.roundsBottom && sheet.bounds.contains(strip.rect)
                                                    && strip.rect.maxY - title.maxY >= InboxOwnershipChrome.footPad - 0.5
                                            } else { correct = false }
                                            if let light = descendants(cell, InboxExpandedGroupLight.self).first, !light.isHidden,
                                               let surface = light.layer?.sublayers?.first {
                                                let corner = CGRect(x: surface.frame.minX, y: surface.frame.maxY - surface.cornerRadius,
                                                    width: surface.frame.width, height: surface.cornerRadius)
                                                correct = correct && surface.cornerRadius > 0 && light.bounds.contains(corner)
                                            }
                                        }
                                    }
                                    if selection != "none" {
                                        inbox.clearSelectionForQA()
                                        inbox.layoutViewportForQA()
                                        let routeCells = [lead, helper, arrival].compactMap { inbox.cellForQA(id: $0) }
                                        let routeLights = routeCells.flatMap { descendants($0, InboxExpandedGroupLight.self) }
                                        let routeWashes = routeCells.flatMap { descendants($0, AgentInboxCardView.self) }.filter {
                                            !$0.qaIndicatorLayers.wash.isHidden && $0.qaIndicatorLayers.wash.superlayer != nil
                                        }
                                        let routeSweeps = routeCells.flatMap { descendants($0, InboxSweepBorderView.self) }
                                        let routePresent = style == .classic ? routeSweeps.contains { !$0.isHidden }
                                            : routeLights.contains { !$0.isHidden } || !routeWashes.isEmpty
                                        let routeMoving = style == .classic ? routeSweeps.contains { $0.isMovingForQA }
                                            : routeLights.contains { !$0.isHidden && $0.renderedLayersForChecks.contains { !($0.animationKeys() ?? []).isEmpty } }
                                                || routeWashes.contains { !($0.qaIndicatorLayers.sheen.animationKeys() ?? []).isEmpty
                                                    || !($0.qaIndicatorLayers.wash.animationKeys() ?? []).isEmpty }
                                        let routeOutlines = routeCells.flatMap { descendants($0, AgentInboxCardView.self) }.filter {
                                                !$0.qaIndicatorLayers.edge.isHidden && $0.qaIndicatorLayers.edge.borderWidth > 0
                                            }.count
                                        correct = correct && routePresent == expected && routeMoving == expected && routeOutlines == 0
                                    }
                                    if correct { passed += 1 } else {
                                        failures.append("\(label): style=\(present) motion=\(moving) expected=\(expected) outlines=\(outlines)")
                                    }
                                }
                            }
                        }
                    }
                    inbox.foldMotionForQA.cancel()
                    window.orderOut(nil)
                    window.contentView = nil
                    window.close()
                    defaults.removePersistentDomain(forName: suite)
                }
            }
        }
        print("SidebarIndicatorTruthTableChecks: \(passed)/\(total) cells passed")
        if !failures.isEmpty { throw Failure(description: failures.prefix(16).joined(separator: "\n")) }
    }
}
