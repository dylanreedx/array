import AppKit
import ContinuumRevivedAgentUI
import Foundation

/// Part of `--sidebar-ux-check`: every icon on a sidebar card sits on its line.
///
/// Read off the SHIPPED list. For each visible icon — status glyph, gyro,
/// folder, host, hover Snooze/Settle, settle nudge, identity dot, branch,
/// provider mark, Copy/Move — the icon's RENDERED ink midY is compared with the
/// x-height centre of its own line's RENDERED text, never with the cached
/// reference the layout used, in Aqua and Dark Aqua. The previous witness
/// compared the folder with that cached reference, so a reference that sat a
/// point high (capital/ascender "Hl") passed it.
@MainActor
enum SidebarIconAlignmentChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let tolerance: CGFloat = 0.5
    static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)
    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "1C000000-0000-4000-8000-%012X", value))!
    }

    static func rows() -> [AgentInboxRow] {
        func row(_ n: Int, _ title: String, state: InboxState, model: String?, branch: String?,
                 identity: String? = nil, unread: Bool = false, ended: Double = 30,
                 where marker: InboxWhereMarker? = nil, external: InboxExternalSession? = nil) -> AgentInboxRow {
            let at = now.addingTimeInterval(-ended)
            return AgentInboxRow(
                id: id(n), title: title, projectName: "roast-web", directoryName: "roast-web",
                state: state, model: model, branch: branch,
                lastActiveAt: at, createdAt: at.addingTimeInterval(-600),
                terminalEvent: state == .ready
                    ? AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: at) : nil,
                terminalIsUnread: unread, identityColor: identity, whereMarker: marker,
                externalSession: external)
        }
        return [
            row(1, "running the review sweep", state: .working, model: "claude-opus-5-5",
                branch: "array/sidebar-swarm", identity: "blue"),
            row(2, "waiting on your approval", state: .approval, model: "gpt-5.5", branch: "fix/caret"),
            row(3, "broke on the migration", state: .failed, model: "claude-sonnet-5-5", branch: "main"),
            row(4, "finished the summary", state: .ready, model: "claude-haiku-5-5", branch: "docs/notes",
                unread: true),
            row(5, "left sitting for a while", state: .ready, model: "gpt-5.5", branch: "chore/tidy",
                ended: 3_600),
            row(6, "another quiet one", state: .ready, model: "claude-opus-5-5", branch: "feat/quiet",
                ended: 7_200),
            row(7, "session in another app", state: .working, model: "claude-opus-5-5", branch: "spike/ports",
                where: InboxWhereMarker(symbol: "terminal", text: "Ghostty"),
                external: InboxExternalSession(sessionKey: "ghostty:7", isProminent: false,
                                               canMoveHere: true, canCopy: true)),
        ]
    }

    static func run() throws -> String {
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        let expected: Set<String> = [
            "status hand.raised.fill", "status exclamationmark.triangle.fill",
            "status checkmark.circle.fill", "gyro (orbit centre)", "folder", "where",
            "hover snooze", "hover settle", "settle nudge icon", "identity dot", "branch",
            "provider mark", "copy icon", "move icon",
        ]
        var seen: Set<String> = []
        var worst: [String: CGFloat] = [:]
        var failures: [String] = []
        // The nudge only offers itself while nothing in the list is blocked, so
        // the settled rows are also drawn on their own.
        let sets = [rows(), rows().filter { $0.state == .ready }]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] { for fixture in sets {
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 340, height: 900))
            inbox.clock = { now }
            inbox.onRowAction = { _, _ in }
            inbox.wiredRowActions = [.settle, .snooze]
            inbox.onExternalSessionAction = { _, _ in }
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            windows.append(window)
            inbox.reload(rows: fixture)
            inbox.layoutForQA()
            func collect(_ state: String) throws {
                for row in fixture {
                    guard let icons = inbox.iconAlignmentForQA(id: row.id) else {
                        throw Failure(description: "\(appearance.rawValue): '\(row.title)' has no card")
                    }
                    for icon in icons {
                        seen.insert(icon.name)
                        worst[icon.name] = max(worst[icon.name] ?? 0, abs(icon.delta))
                        if abs(icon.delta) > tolerance {
                            failures.append(String(
                                format: "%@ %@ '%@': %@ ink %.2f vs '%@' x-height %.2f (%.2fpt)",
                                appearance.rawValue, state, row.title, icon.name, icon.inkMidY,
                                icon.neighbour, icon.lineCentreY, icon.delta))
                        }
                    }
                }
            }
            try collect("rest")
            for row in fixture {
                guard inbox.hoverRowForQA(id: row.id) else {
                    throw Failure(description: "\(appearance.rawValue): could not hover '\(row.title)'")
                }
                inbox.layoutForQA()
                guard let icons = inbox.iconAlignmentForQA(id: row.id) else { continue }
                for icon in icons where icon.name.hasPrefix("hover") || icon.name.hasSuffix("icon") {
                    seen.insert(icon.name)
                    worst[icon.name] = max(worst[icon.name] ?? 0, abs(icon.delta))
                    if abs(icon.delta) > tolerance {
                        failures.append(String(
                            format: "%@ hover '%@': %@ ink %.2f vs '%@' x-height %.2f (%.2fpt)",
                            appearance.rawValue, row.title, icon.name, icon.inkMidY,
                            icon.neighbour, icon.lineCentreY, icon.delta))
                    }
                }
            }
            _ = inbox.hoverRowForQA(id: nil)
        } }
        let missing = expected.subtracting(seen)
        guard missing.isEmpty else {
            throw Failure(description: "sidebar-icon-alignment: the fixture never drew \(missing.sorted()) — the witness must see every icon kind")
        }
        let report = worst.sorted { $0.key < $1.key }
            .map { String(format: "%@ %.2f", $0.key, $0.value) }.joined(separator: ", ")
        guard failures.isEmpty else {
            throw Failure(description: "sidebar-icon-alignment: icon ink off its line's x-height centre (tolerance \(tolerance)pt):\n  "
                + failures.joined(separator: "\n  ") + "\n  worst: " + report)
        }
        return "sidebar-icon-alignment: \(seen.count) icon kinds on their line's rendered x-height centre in aqua+darkAqua, worst |delta| per kind: \(report)"
    }
}
