import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// The selected agent looks the same whatever selected it: a sidebar click, a
/// tile focused on the canvas (with or without an older table selection left on
/// another row), ⌘-jump, or Return after arrowing to it. That is how 0.7.47
/// behaved, because every one of those ends at the open agent; the preview that
/// followed added an outline and a style rule keyed to the TABLE selection, so a
/// canvas focus after clicking another row left the focused group unlit and the
/// outline on the old row.
///
/// Inputs arrive the way production delivers them: clicks and keys through
/// `NSApp.sendEvent`, ⌘-jump through `AgentInboxView.jump` (what
/// `handleInboxJump` calls), canvas focus as `openAgentId` (what
/// `setInboxOpenAgent` writes), and a reveal sets `openAgentId` as the host does.
@MainActor
enum SidebarSelectionParityChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    struct Treatment: Equatable, CustomStringConvertible {
        var role: String
        var wash: Bool
        var cardMotion: Bool
        var groupLight: Bool
        var groupMotion: Bool
        var sweep: Bool
        var description: String {
            "role=\(role) wash=\(wash) cardMotion=\(cardMotion) groupLight=\(groupLight) groupMotion=\(groupMotion) sweep=\(sweep)"
        }
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
        var cases = 0
        var drawnAlike = 0
        let lead = uuid(0x100), helperA = uuid(0x101), helperB = uuid(0x102)
        let single = uuid(0x300), other = uuid(0x200)
        let now = Date()
        func row(_ id: UUID, _ title: String, working: Bool, parent: UUID? = nil, colour: String? = nil,
                 minutes: Double) -> AgentInboxRow {
            AgentInboxRow(id: id, title: title, state: working ? .working : .ready,
                          lastActiveAt: now.addingTimeInterval(-minutes * 60), depth: parent == nil ? 0 : 1,
                          createdAt: now.addingTimeInterval(-(minutes + 5) * 60), parentId: parent,
                          identityColor: colour)
        }
        let rows = [
            row(lead, "Lead", working: true, colour: "red", minutes: 0),
            row(helperA, "Helper A", working: true, parent: lead, minutes: 0.1),
            row(helperB, "Helper B", working: true, parent: lead, minutes: 0.2),
            row(single, "Single", working: true, colour: "mint", minutes: 1),
            row(other, "Other", working: false, colour: "blue", minutes: 6),
        ]
        for style in [SidebarActiveIndicatorStyle.duplex, .classic] {
            for dark in [false, true] {
                let suite = "array.selection-parity.\(UUID().uuidString)"
                let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(style.rawValue, forKey: SidebarActiveIndicatorStyle.defaultsKey)
                let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 340, height: 560), indicatorDefaults: defaults)
                inbox.prefersReducedMotion = { false }
                inbox.hoverCardEnabled = false
                inbox.foldsUntouchedGroups = false
                inbox.onRevealRow = { [weak inbox] id in inbox?.openAgentId = id }
                let window = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = inbox
                window.orderFrontOffscreenForChecks()
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                inbox.setScope(.all)
                inbox.restoreParentFolds([lead: true])
                inbox.reload(rows: rows)
                inbox.layoutViewportForQA()
                guard let table = descendants(inbox, NSTableView.self).first else { throw Failure(description: "no table") }

                func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "no mouse event") }
                    return event
                }
                func click(_ id: UUID) throws {
                    inbox.layoutViewportForQA()
                    guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "no row to click") }
                    let y = cell.isFlipped ? 9 : cell.bounds.height - 9
                    let point = cell.convert(NSPoint(x: cell.bounds.width * 0.55, y: y), to: nil)
                    NSApp.postEvent(try mouse(.leftMouseUp, point), atStart: false)
                    NSApp.sendEvent(try mouse(.leftMouseDown, point))
                    pump()
                }
                func key(_ code: UInt16, _ character: Int) throws {
                    let text = String(UnicodeScalar(character)!)
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                        throw Failure(description: "no key event")
                    }
                    NSApp.sendEvent(event)
                    pump()
                }
                func reset() {
                    inbox.openAgentId = nil
                    inbox.clearSelectionForQA()
                    inbox.layoutViewportForQA()
                    pump()
                }
                func treatment(_ id: UUID) throws -> Treatment {
                    inbox.layoutViewportForQA()
                    pump()
                    guard let cell = inbox.cellForQA(id: id),
                          let card = descendants(cell, AgentInboxCardView.self).first else {
                        throw Failure(description: "no card for \(id)")
                    }
                    let layers = card.qaIndicatorLayers
                    let lights = descendants(cell, InboxExpandedGroupLight.self).filter { !$0.isHidden }
                    return Treatment(
                        role: "\(card.surfaceRole)",
                        wash: !layers.wash.isHidden && layers.wash.superlayer != nil,
                        cardMotion: !(layers.sheen.animationKeys() ?? []).isEmpty
                            || !(layers.wash.animationKeys() ?? []).isEmpty,
                        groupLight: !lights.isEmpty,
                        groupMotion: lights.contains { $0.renderedLayersForChecks.contains { !($0.animationKeys() ?? []).isEmpty } },
                        sweep: descendants(cell, InboxSweepBorderView.self).contains { !$0.isHidden })
                }
                /// 0.7.47 never painted a selection outline on any card.
                func outlines() -> [String] {
                    descendants(inbox, AgentInboxCardView.self).compactMap { card in
                        let edge = card.qaIndicatorLayers.edge
                        return !edge.isHidden && edge.superlayer != nil && edge.borderWidth > 0
                            ? "outline \(edge.borderWidth)pt" : nil
                    }
                }
                /// ⌘1…⌘9 until the jump lands on `id`, each from a clean state.
                func jump(to id: UUID) -> Bool {
                    for code: UInt16 in [18, 19, 20, 21, 23, 22, 26, 28, 25] {
                        reset()
                        guard inbox.jump(keyCode: code, modifiers: .command) else { return false }
                        pump()
                        if inbox.selectedRowIdsForQA == [id] { return true }
                    }
                    return false
                }

                for target in [lead, single] {
                    let label = "\(style.rawValue)/\(dark ? "dark" : "light")/\(target == lead ? "lead" : "single")"
                    let away = target == lead ? single : lead
                    var seen: [(String, Treatment, [String])] = []
                    // A sidebar click.
                    reset()
                    try click(target)
                    seen.append(("sidebar click", try treatment(target), outlines()))
                    // A tile focused on the canvas, nothing selected in the table.
                    reset()
                    inbox.openAgentId = target
                    seen.append(("canvas focus", try treatment(target), outlines()))
                    // A tile focused on the canvas after a click on another row: the
                    // table still holds that older selection.
                    reset()
                    try click(away)
                    inbox.openAgentId = target
                    seen.append(("canvas focus after another click", try treatment(target), outlines()))
                    // ⌘-jump.
                    if jump(to: target) {
                        seen.append(("quick jump", try treatment(target), outlines()))
                    } else {
                        failures.append("\(label): ⌘-jump did not reach the row")
                    }
                    // Arrow to it from another row, then Return to open it.
                    reset()
                    try click(away)
                    window.makeFirstResponder(table)
                    let code: UInt16 = target == lead ? 126 : 125
                    let arrow = target == lead ? NSUpArrowFunctionKey : NSDownArrowFunctionKey
                    for _ in 0..<6 where inbox.selectedRowIdsForQA != [target] { try key(code, arrow) }
                    try key(36, 13)
                    seen.append(("arrows then Return", try treatment(target), outlines()))

                    cases += seen.count
                    let reference = seen[0].1
                    for (input, got, drawn) in seen {
                        if got != reference {
                            failures.append("\(label): \(input) drew \(got); a sidebar click draws \(reference)")
                        }
                        if !drawn.isEmpty {
                            failures.append("\(label): \(input) painted \(drawn.count) selection outline(s); 0.7.47 paints none")
                        }
                        if got == reference && drawn.isEmpty { drawnAlike += 1 }
                    }
                    if !(reference.groupLight || reference.wash || reference.sweep) {
                        failures.append("\(label): the selected working agent shows no style at all (\(reference))")
                    }
                }
            }
        }
        print("SidebarSelectionParityChecks: \(drawnAlike)/\(cases) selections drawn alike, no outline")
        if !failures.isEmpty { throw Failure(description: failures.prefix(20).joined(separator: "\n")) }
    }
}
