import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// A running agent's style stays on through every fold. Dylan, on the preview:
/// "when I collapse subagents, the style disappears but IT SHOULD BE ACTIVE when an
/// agent is running". The preview counted the table selection as "selected", and a
/// fold drops the table selection (as 0.7.47 did), so the style went with it.
///
/// Driven the way production delivers it: the row click and every disclosure press
/// arrive through `NSApp.sendEvent`, and a reveal sets `openAgentId` as the host does
/// once it has focused the tile (`setInboxOpenAgent`). Both scopes, all four styles.
@MainActor
enum SidebarFoldStyleChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    static func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        CATransaction.flush()
    }

    static func run() throws {
        var failures: [String] = []
        var steps = 0
        let leadA = uuid(0x100), helperA1 = uuid(0x101), helperA2 = uuid(0x102), arrival = uuid(0x103)
        let leadB = uuid(0x200), helperB1 = uuid(0x201)
        let single = uuid(0x300)
        let now = Date()
        func row(_ id: UUID, _ title: String, working: Bool, parent: UUID? = nil, colour: String? = nil,
                 minutes: Double) -> AgentInboxRow {
            AgentInboxRow(id: id, title: title, state: working ? .working : .ready,
                          lastActiveAt: now.addingTimeInterval(-minutes * 60), depth: parent == nil ? 0 : 1,
                          createdAt: now.addingTimeInterval(-(minutes + 5) * 60), parentId: parent,
                          identityColor: colour)
        }
        let rows = [
            row(leadA, "Lead A", working: true, colour: "red", minutes: 0),
            row(helperA1, "Helper A1", working: true, parent: leadA, minutes: 0.1),
            row(helperA2, "Helper A2", working: false, parent: leadA, minutes: 3),
            row(leadB, "Lead B", working: true, colour: "blue", minutes: 1),
            row(helperB1, "Helper B1", working: true, parent: leadB, minutes: 1.1),
            row(single, "Single", working: false, colour: "mint", minutes: 6),
        ]
        let withArrival = rows + [row(arrival, "Helper A3", working: true, parent: leadA, minutes: 0.05)]

        for style in SidebarActiveIndicatorStyle.allCases {
            for scope in SidebarActiveIndicatorScope.allCases {
              // `hostFollows`: the host has focused A's tile and set it open, as it does
              // once a sidebar reload lands. Otherwise the open agent is still the
              // tile focused before (here the idle single), which is what the sidebar
              // holds until that reload: the style must then not CHANGE on a fold.
              for hostFollows in [true, false] {
                let label = "\(style.rawValue)/\(scope.rawValue)/\(hostFollows ? "open follows click" : "open elsewhere")"
                let suite = "array.fold-style.\(UUID().uuidString)"
                let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(style.rawValue, forKey: SidebarActiveIndicatorStyle.defaultsKey)
                defaults.set(scope.rawValue, forKey: SidebarActiveIndicatorScope.defaultsKey)
                let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 340, height: 620), indicatorDefaults: defaults)
                inbox.prefersReducedMotion = { false }
                inbox.hoverCardEnabled = false
                inbox.foldsUntouchedGroups = false
                inbox.onRevealRow = { [weak inbox] id in if hostFollows { inbox?.openAgentId = id } }
                inbox.openAgentId = hostFollows ? nil : single
                let window = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = inbox
                window.orderFrontOffscreenForChecks()
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                inbox.setScope(.all)
                inbox.restoreParentFolds([leadA: true, leadB: true])
                inbox.reload(rows: rows)
                inbox.layoutViewportForQA()

                /// Whether lead A's group shows its style on any row still drawn.
                func styled() -> Bool {
                    let cells = [leadA, helperA1, helperA2, arrival].compactMap { inbox.cellForQA(id: $0) }
                    if style == .classic {
                        return cells.flatMap { descendants($0, InboxSweepBorderView.self) }.contains { !$0.isHidden }
                    }
                    let lights = cells.flatMap { descendants($0, InboxExpandedGroupLight.self) }.contains { !$0.isHidden }
                    let washes = cells.flatMap { descendants($0, AgentInboxCardView.self) }.contains {
                        !$0.qaIndicatorLayers.wash.isHidden && $0.qaIndicatorLayers.wash.superlayer != nil
                    }
                    return lights || washes
                }
                // A running agent is always lit under "All working agents", and when it is
                // the open agent; otherwise what the click showed may not change.
                let mustShow = hostFollows || scope == .working
                var shownAtClick: Bool?
                func expect(_ step: String) {
                    steps += 1
                    let shown = styled()
                    if shownAtClick == nil { shownAtClick = shown }
                    if mustShow ? !shown : shown != shownAtClick {
                        failures.append("\(label): \(step): lead A style \(shown), \(mustShow ? "must show" : "showed \(shownAtClick!) at the click") (open \(String(describing: inbox.openAgentId)), selected \(inbox.selectedRowIdsForQA))")
                    }
                }

                func press(at point: NSPoint) throws {
                    func event(_ type: NSEvent.EventType) throws -> NSEvent {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                            throw Failure(description: "no mouse event")
                        }
                        return event
                    }
                    NSApp.postEvent(try event(.leftMouseUp), atStart: false)
                    NSApp.sendEvent(try event(.leftMouseDown))
                    pump()
                }
                func clickRow(_ id: UUID) throws {
                    inbox.layoutViewportForQA()
                    guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "\(label): no row to click") }
                    let y = cell.isFlipped ? 9 : cell.bounds.height - 9
                    try press(at: cell.convert(NSPoint(x: cell.bounds.width * 0.55, y: y), to: nil))
                }
                /// The fold control's own press, then 25 ms of the fold so the mid-fold
                /// frame is measured, then the fold settles.
                func fold(_ lead: UUID, _ name: String) throws {
                    inbox.layoutViewportForQA()
                    guard let cell = inbox.cellForQA(id: lead),
                          let control = descendants(cell, InboxSwarmFoldControl.self).first(where: { !$0.isHidden }) else {
                        throw Failure(description: "\(label): no fold control on \(name)")
                    }
                    try press(at: control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil))
                    inbox.foldMotionForQA.advance(by: 0.025)
                    expect("\(name), mid-fold")
                    inbox.foldMotionForQA.cancel()
                    inbox.layoutViewportForQA()
                    pump()
                    expect(name)
                }
                try clickRow(leadA)
                expect("click lead A")
                try fold(leadA, "collapse A")
                try fold(leadA, "expand A")
                try fold(leadA, "collapse A again")
                try fold(leadB, "collapse B")
                inbox.apply(rows: withArrival,
                            changed: AgentsBoardChangeSet(added: [arrival], updated: [leadA], removed: []))
                inbox.layoutViewportForQA()
                pump()
                expect("helper added live")
                try fold(leadA, "expand A with the new helper")
              }
            }
        }
        print("SidebarFoldStyleChecks: \(steps - failures.count)/\(steps) steps kept a running lead's style through folds")
        if !failures.isEmpty { throw Failure(description: failures.prefix(20).joined(separator: "\n")) }
    }
}
