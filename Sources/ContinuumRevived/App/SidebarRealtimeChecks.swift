import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--sidebar-realtime-check`. Deleting, folding and unfolding a row must reach
/// the table while agents stream, on a list long enough to take the off-main
/// display path (Dylan's store has ~1,600 agents).
///
/// The production `AgentInboxView` gets a push every few milliseconds, faster
/// than one off-main display build, as streaming agents push. Under that stream:
/// Delete is picked from the row menu (the host's answer is the push without the
/// agent), then the lead is folded and unfolded by real clicks on its fold
/// control through `NSApp.sendEvent`. After each, the witness reads the row
/// views the table holds in its viewport, with no reload of its own.
///
/// Before the fix, every finished off-main build was thrown away because a newer
/// push had arrived while it ran, so no swap ever landed: the deleted row stayed
/// on screen, and the fold re-rendered from the last applied rows and kept
/// drawing it.
@MainActor
enum SidebarRealtimeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let now = Date(timeIntervalSinceReferenceDate: 820_000_000)
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "2E000000-0000-4000-8000-%012X", n))! }

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// `leads` leads, each with `recent` finished helpers and `old` long-finished ones.
    static func rows(leads: Int, recent: Int, old: Int) -> [AgentInboxRow] {
        func row(_ n: Int, _ title: String, parent: Int?, age: Double) -> AgentInboxRow {
            let ended = now.addingTimeInterval(-age)
            return AgentInboxRow(
                id: id(n), title: title, projectName: "Array", directoryName: "Array",
                state: .ready, model: "claude-opus-5-5", lastActiveAt: ended, depth: parent == nil ? 0 : 1,
                createdAt: now.addingTimeInterval(-age - 600), parentId: parent.map(id),
                terminalEvent: AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: ended),
                identityColor: parent == nil ? "teal" : nil)
        }
        var out: [AgentInboxRow] = []
        for l in 0..<leads {
            let lead = (l + 1) * 1000
            out.append(row(lead, "Lead \(l + 1)", parent: nil, age: 60 + Double(l) * 60))
            for h in 0..<recent {
                out.append(row(lead + 1 + h, "Helper \(l + 1).\(h + 1)", parent: lead, age: 70 + Double(l) * 60 + Double(h)))
            }
            for h in 0..<old {
                out.append(row(lead + 100 + h, "Old \(l + 1).\(h + 1)", parent: lead, age: 7200 + Double(h)))
            }
        }
        return out
    }

    static func spin(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
    }

    static func run() throws -> String {
        let suite = "ArraySidebarRealtime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Agent icons on: the Halo lead icon is the fold control, as in 0.7.59.
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        controller.reload()

        var pushed = rows(leads: 15, recent: 3, old: 62)
        guard pushed.count >= AgentInboxView.offMainRowThreshold else {
            throw Failure(description: "fixture of \(pushed.count) rows does not take the off-main path")
        }
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 620), indicatorDefaults: defaults)
        inbox.clock = { now }
        inbox.prefersReducedMotion = { false }
        inbox.hoverCardEnabled = false
        inbox.foldsUntouchedGroups = false
        inbox.wiredRowActions = [.delete]
        // The host's Delete: archive the agent, then push the rows without it.
        inbox.onRowAction = { action, ids in
            guard action == .delete else { return }
            pushed.removeAll { ids.contains($0.id) }
            inbox.apply(rows: pushed, changed: AgentsBoardChangeSet(added: [], updated: [], removed: Set(ids)))
        }
        let window = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        inbox.apply(rows: pushed, changed: AgentsBoardChangeSet(added: Set(pushed.map(\.id)), updated: [], removed: []))
        inbox.flushOffMainApplyForQA()
        inbox.layoutForQA()

        let lead = id(1000)
        let helpers = [id(1001), id(1002), id(1003)]
        let deleted = helpers[0]
        let drawn0 = Set(inbox.drawnAgentIdsForQA)
        guard drawn0.isSuperset(of: [lead] + helpers) else {
            throw Failure(description: "setup: Lead 1 and its helpers are not on screen (\(drawn0.count) rows drawn)")
        }

        // Streaming agents: a push every few milliseconds, each moving one agent's
        // last turn — faster than one off-main display build of this list.
        var pushes = 0
        let streamer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                pushes += 1
                let target = id(5000)
                pushed = pushed.map { row in
                    guard row.id == target else { return row }
                    var next = row
                    next.lastTurnAt = now.addingTimeInterval(Double(pushes))
                    return next
                }
                inbox.apply(rows: pushed, changed: AgentsBoardChangeSet(added: [], updated: [target], removed: []))
            }
        }
        RunLoop.main.add(streamer, forMode: .common)
        defer { streamer.invalidate() }
        spin(0.2)

        // 1. Delete a helper from its row menu.
        let swaps0 = inbox.qaOffMainSwapCount
        guard inbox.openRowMenuForQA(clickedRowId: deleted), inbox.pickRowMenuItemForQA(.delete) else {
            throw Failure(description: "delete: the row menu offered no Delete")
        }
        var waited = 0.0
        while inbox.drawnAgentIdsForQA.contains(deleted), waited < 1.5 { spin(0.02); waited += 0.02 }
        let swaps = inbox.qaOffMainSwapCount - swaps0
        guard !inbox.drawnAgentIdsForQA.contains(deleted) else {
            throw Failure(description: "delete: the deleted helper is still drawn \(String(format: "%.1f", waited)) s later "
                + "(\(pushes) pushes, \(swaps) off-main swaps landed)")
        }
        let deleteLatency = waited

        // 2. Fold the lead by clicking its fold control.
        func clickFold() throws {
            guard let control = inbox.cellForQA(id: lead)?.qaFoldControlForQA else {
                throw Failure(description: "no fold control on Lead 1")
            }
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0) else { throw Failure(description: "no mouse event") }
                NSApp.sendEvent(event)
            }
        }
        func assertDrawn(_ step: String, shows: [UUID], hides: [UUID]) throws {
            let drawn = Set(inbox.drawnAgentIdsForQA)
            let missing = shows.filter { !drawn.contains($0) }
            let stale = hides.filter { drawn.contains($0) }
            guard missing.isEmpty, stale.isEmpty else {
                throw Failure(description: "\(step): \(missing.count) rows missing and \(stale.count) rows that should be gone still drawn "
                    + "(deleted helper drawn: \(drawn.contains(deleted)))")
            }
        }
        try clickFold()
        try assertDrawn("fold, straight after the click", shows: [lead], hides: helpers)
        spin(0.5)
        try assertDrawn("fold, 0.5 s on", shows: [lead], hides: helpers)

        // 3. Unfold it again: the two remaining helpers return, the deleted one does not.
        try clickFold()
        try assertDrawn("unfold, straight after the click", shows: [lead] + helpers.dropFirst(), hides: [deleted])
        spin(0.5)
        try assertDrawn("unfold, 0.5 s on", shows: [lead] + helpers.dropFirst(), hides: [deleted])

        return String(format: "sidebar realtime: %d rows, a push every 4 ms (%d pushes); Delete drawn in %.2f s with %d off-main swaps; "
                      + "fold and unfold drawn straight after the click and held 0.5 s", pushed.count, pushes, deleteLatency, swaps)
    }
}
