import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--sidebar-hover-text-check` — hovering a sidebar row reveals its actions
/// (Share, Snooze, Settle, Pop out, Stop) and must not re-lay-out the row's text:
/// Dylan saw the branch truncate on hover when it fits, which flickered. The
/// pointer is driven through `AgentInboxView.mouseMoved`, the production hover
/// path, in both sidebar layouts. For each row the text frames before and after
/// hover are compared; a long branch must keep the same truncation and fade
/// under the actions instead.
@MainActor
enum SidebarHoverTextChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        print("PASS sidebar hover text: \(label)")
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static func row(_ title: String, branch: String, parent: UUID? = nil) -> AgentInboxRow {
        let now = Date()
        return AgentInboxRow(
            id: UUID(), title: title, projectName: "checkout-web", projectId: UUID(),
            workspaceName: "A", workspaceId: UUID(), state: .ready, lifecycle: .active,
            model: "claude-opus-5-5", branch: branch, elapsed: nil, elapsedStartedAt: nil,
            lastActiveAt: now, depth: parent == nil ? 0 : 1, createdAt: now, parentId: parent,
            harness: "Claude Code", terminalEvent: nil, terminalIsUnread: false, identityColor: nil,
            selfReport: nil, hasTile: true, isPinned: false)
    }

    static func run(snapshotDirectory: URL? = nil) async throws {
        for layout in SidebarLayout.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                try await runOne(layout: layout, appearance: appearance, snapshotDirectory: snapshotDirectory)
            }
        }
    }

    private static func runOne(layout: SidebarLayout, appearance: NSAppearance.Name, snapshotDirectory: URL?) async throws {
        let tag = "\(layout.rawValue)/\(appearance == .aqua ? "light" : "dark")"
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        inbox.prefersReducedMotion = { true }
        inbox.hoverCardEnabled = false
        inbox.onRevealRow = { _ in }
        inbox.onRowAction = { _, _ in }
        inbox.wiredRowActions = [.share, .settle, .snooze, .popOut, .stopAgent]
        inbox.setSidebarLayoutForQA(layout)
        let window = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        inbox.setScope(.all)
        let fits = row("Fix toggle", branch: "main")
        let long = row("Audit the receipt email path", branch: "checkout/retry-the-receipt-email-after-a-card-decline-on-saved-cards")
        inbox.reload(rows: [(fits, fits.title), (long, long.title)].map { $0.0 })
        inbox.layoutForQA()

        func hover(_ cell: AgentInbox96CellView) throws {
            cell.layoutSubtreeIfNeeded()
            let point = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
            else { throw Failure(description: "could not synthesise a pointer move") }
            inbox.mouseMoved(with: event)
            inbox.layoutForQA()
            cell.layoutSubtreeIfNeeded()
        }

        for (name, agent, mustFade) in [("fitting", fits, false), ("long branch", long, true)] {
            guard let cell = inbox.ownershipCellForQA(id: agent.id) else { throw Failure(description: "\(tag): no row for \(name)") }
            cell.layoutSubtreeIfNeeded()
            let before = cell.qaTextFramesForQA
            try expect(cell.qaVisibleActionFramesForQA.isEmpty && cell.qaFadedLabelsForQA.isEmpty,
                "\(tag) \(name): at rest no action shows and no text is faded")
            try hover(cell)
            let actions = cell.qaVisibleActionFramesForQA
            try expect(!actions.isEmpty, "\(tag) \(name): hovering shows the row's actions")
            try expect(cell.qaTextFramesForQA == before,
                "\(tag) \(name): hover leaves every text frame as it was (\(before) -> \(cell.qaTextFramesForQA))")
            if mustFade {
                try expect(cell.qaFadedLabelsForQA.contains("branch"),
                    "\(tag) \(name): the long branch fades under the actions")
            } else {
                try expect(cell.qaFadedLabelsForQA.isEmpty,
                    "\(tag) \(name): text that fits is not faded (\(cell.qaFadedLabelsForQA))")
            }
            if let directory = snapshotDirectory { try snapshot(cell, directory, "\(name.replacingOccurrences(of: " ", with: "-"))-\(tag.replacingOccurrences(of: "/", with: "-"))-hover") }
            inbox.mouseExited(with: NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            inbox.layoutForQA(); cell.layoutSubtreeIfNeeded()
            try expect(cell.qaTextFramesForQA == before, "\(tag) \(name): leaving restores the same frames")
        }
    }

    private static func snapshot(_ view: NSView, _ directory: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
