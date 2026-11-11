import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

@MainActor
enum SidebarPressFeedbackChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        QuickHideChecks.acceptFirstMouseEverywhere()
        func cards(_ view: NSView) -> [AgentInboxCardView] {
            ((view as? AgentInboxCardView).map { [$0] } ?? []) + view.subviews.flatMap(cards)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 380, height: 700))
            let lead = UUID(), helper = UUID()
            inbox.reload(rows: [AgentInboxRow(id: lead, title: "Press lead", state: .working, createdAt: Date()),
                AgentInboxRow(id: helper, title: "Press helper", state: .working, depth: 1, createdAt: Date(), parentId: lead)])
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            inbox.layoutViewportForQA()
            guard inbox.rowCursorsForQA().contains(.pointingHand) else {
                throw Failure(description: "clickable rows lack pointing-hand cursor rects")
            }
            for id in [lead, helper] {
                guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "missing cell") }
                let point = cell.convert(NSPoint(x: cell.bounds.width / 2, y: cell.bounds.height / 2), to: nil)
                var revealed = false
                var painted = false
                var handoff: Double = 0
                let start = CACurrentMediaTime()
                inbox.onRevealRow = { selected in
                    revealed = selected == id
                    handoff = (CACurrentMediaTime() - start) * 1000
                    if let current = inbox.cellForQA(id: id), let card = cards(current).first {
                        painted = card.layer?.backgroundColor != nil && card.layer?.animation(forKey: AgentInboxCardView.fillFadeKey) == nil
                    }
                }
                func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                        throw Failure(description: "event creation failed")
                    }
                    return event
                }
                NSApp.postEvent(try event(.leftMouseUp), atStart: true)
                NSApp.sendEvent(try event(.leftMouseDown))
                if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(up) }
                guard revealed && painted else { throw Failure(description: "press was not painted without a fade before reveal") }
                print("SidebarPressFeedback \(appearance.rawValue) \(id == lead ? "lead" : "helper"): event→sidebar reveal handoff \(handoff) ms; committed press precedes handoff")
            }
        }
    }
}
