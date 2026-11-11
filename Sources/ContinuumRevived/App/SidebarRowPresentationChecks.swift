import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Sample the render-server presentation, not the model geometry, across real
/// status pushes and helper arrivals in an expanded active family.
@MainActor
enum SidebarRowPresentationChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() async throws -> String {
        try SidebarSelectionGeometryChecks.run()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"]
            ?? "qa-runs/sidebar-row-presentation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var log = ["style,phase,frame,time,id,slotY,presentationY,height,animations"]
        var failures: [String] = []
        defer { try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8) }
        let lead = UUID(), children = (0..<4).map { _ in UUID() }
        let now = Date()
        var stableWorkingPair = false
        func fixture(done: Bool, arrival: Bool) -> [AgentInboxRow] {
            let neighbour = AgentInboxRow(id: UUID(uuidString: "AABB0000-0000-4000-8000-000000000001")!,
                title: "Earlier lead", state: .working, createdAt: now.addingTimeInterval(30))
            let parent = AgentInboxRow(id: lead, title: "Active teal lead", state: .working,
                createdAt: now, identityColor: "teal")
            return [neighbour, parent] + (0..<(arrival ? 4 : 3)).map { index in
                AgentInboxRow(id: children[index], title: "Helper \(index)",
                    state: (index == 1 && !done) || (stableWorkingPair && index == 0) || index == 3 ? .working : .ready,
                    lastActiveAt: now, depth: 1, createdAt: now.addingTimeInterval(Double(index == 3 ? 10 : 4-index)), parentId: lead)
            }
        }
        for style in ["current", "gradient", "sheen", "duplex"] {
            for startsCollapsed in [false, true] {
            let suite = "array.row-presentation.\(UUID().uuidString)"
            let defaults = QAIsolatedDefaults(isolatedSuiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(style, forKey: SidebarActiveIndicatorStyle.defaultsKey)
            let inbox = AgentInboxView(frame: NSRect(x: 0,y: 0,width: 380,height: 700), indicatorDefaults: defaults)
            if startsCollapsed { inbox.restoreParentFolds([lead: false]) }
            inbox.prepareRowPresentationCaptureForQA()
            inbox.prefersReducedMotion = { false }
            inbox.openAgentId = lead
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            func press() throws {
                guard let control = inbox.cellForQA(id: lead)?.qaFoldControlForQA else {
                    throw Failure(description: "missing disclosure")
                }
                let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure(description: "event") }
                    NSApp.sendEvent(event)
                }
            }
            inbox.reload(rows: fixture(done: false, arrival: false))
            inbox.layoutViewportForQA()
            try await Task.sleep(for: .milliseconds(250))
            for cycle in 0..<2 {
                // Cycle zero is the first interaction with default-expanded rows;
                // subsequent cycles also cover a settled collapsed starting state.
                if !startsCollapsed || cycle > 0 { try press() }
                try await Task.sleep(for: .milliseconds(250))
                guard children.prefix(3).allSatisfy({ !inbox.rowIdsForQA.contains($0) }) else {
                    throw Failure(description: "disclosure did not collapse the group")
                }
                try press()
                guard children.prefix(3).allSatisfy(inbox.rowIdsForQA.contains) else {
                    throw Failure(description: "disclosure did not expand the group")
                }
                var restingCards: [UUID: NSRect] = [:]
                for id in [lead] + Array(children.prefix(3)) {
                    guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "missing model card") }
                    restingCards[id] = cell.convert(cell.qaTuckedCardsForQA.card, to: inbox)
                }
                for frame in 0..<32 {
                    CATransaction.flush()
                    try await Task.sleep(for: .nanoseconds(8_333_333))
                    let samples = inbox.rowPresentationFramesForQA(cardBounds: true)
                    let helpers = samples.filter { children.contains($0.0) }.sorted { $0.1.minY < $1.1.minY }
                    if helpers.count != 3 { throw Failure(description: "missing helper presentation") }
                    for pair in zip(helpers, helpers.dropFirst()) {
                        let finalGap = restingCards[pair.1.0]!.minY - restingCards[pair.0.0]!.maxY
                        let actualGap = pair.1.2.minY - pair.0.2.maxY
                        if abs(finalGap - actualGap) > 0.5, failures.count < 12 {
                            failures.append("\(style)/initial-collapsed-\(startsCollapsed)-cycle-\(cycle) frame \(frame): gap \(actualGap), final \(finalGap)")
                        }
                    }
                    for (id, slot, presented, animations) in helpers {
                        log.append("\(style),initial-collapsed-\(startsCollapsed)-cycle-\(cycle),\(frame),\(CACurrentMediaTime()),\(id),\(slot.minY),\(presented.minY),\(presented.height),\(animations.joined(separator: ";"))")
                        let final = restingCards[id]!
                        let origin = restingCards[lead]!
                        let envelope = final.union(origin).insetBy(dx: -0.5, dy: -0.5)
                        if presented.minY < envelope.minY || presented.maxY > envelope.maxY, failures.count < 12 {
                            failures.append("\(style)/initial-collapsed-\(startsCollapsed)-cycle-\(cycle): helper escaped its origin-to-slot span")
                        }
                    }
                }
            }
            for phase in ["expanded", "reload", "route", "sorted", "unfolding", "unfolding-reload", "unfolding-route", "unfolding-stable"] {
                stableWorkingPair = phase == "unfolding-stable"
                inbox.openAgentId = lead
                inbox.setSortMode(phase == "sorted" ? .mostActive : .newest)
                inbox.reload(rows: fixture(done: false, arrival: false))
                inbox.layoutViewportForQA()
                try await Task.sleep(for: .milliseconds(220))
                if phase.hasPrefix("unfolding") {
                    inbox.toggleCollapse(parentId: lead)
                    try await Task.sleep(for: .milliseconds(200))
                    inbox.toggleCollapse(parentId: lead)
                }
                var measured = 0
                for frame in 0..<96 {
                    if frame == 2 || frame == 36 {
                        if phase.hasSuffix("route") { inbox.openAgentId = children[1] }
                        if phase.hasSuffix("reload") || phase.hasSuffix("route") {
                            inbox.reload(rows: fixture(done: true, arrival: frame >= 36))
                        } else {
                            inbox.apply(rows: fixture(done: true, arrival: frame >= 36),
                                changed: AgentsBoardChangeSet(added: frame >= 36 ? [children[3]] : [],
                                    updated: [children[1]], removed: []))
                        }
                    }
                    CATransaction.flush()
                    try await Task.sleep(for: .nanoseconds(8_333_333))
                    let time = CACurrentMediaTime()
                    let samples = inbox.rowPresentationFramesForQA()
                    measured += samples.count
                    let expected = Set([lead] + Array(children.prefix(frame >= 40 ? 4 : 3)))
                    if !expected.isSubset(of: Set(samples.map { $0.0 })), failures.count < 12 {
                        failures.append("\(style)/\(phase) frame \(frame): an existing visible row lost its presentation layer")
                    }
                    for (id, slot, presented, animations) in samples {
                        log.append("\(style),\(phase),\(frame),\(time),\(id),\(slot.minY),\(presented.minY),\(presented.height),\(animations.joined(separator: ";"))")
                        // While a user-requested unfold is still moving, its
                        // legitimate path remains below the parent, never at origin.
                        let parentSlot = samples.first { $0.0 == lead }?.1 ?? slot
                        let family = children.contains(id)
                        let allowedMotion = family && ((phase.hasPrefix("unfolding") && frame < 20)
                            || (phase == "sorted" && ((2..<24).contains(frame) || (36..<58).contains(frame))))
                        let familySlots = samples.filter { children.contains($0.0) || $0.0 == lead }.map { $0.1 }
                        let familyBounds = familySlots.reduce(parentSlot) { $0.union($1) }
                        let envelope = (phase == "sorted" ? familyBounds : slot.union(parentSlot)).insetBy(dx: 0, dy: -8)
                        let bad = allowedMotion
                            ? !envelope.contains(NSPoint(x: envelope.midX, y: presented.midY))
                            : presented.minY < slot.minY - 1 || presented.maxY > slot.maxY + 1
                        if bad && failures.count < 12 {
                            failures.append("\(style)/\(phase) frame \(frame) \(id): presentation y=\(presented.minY), slot y=\(slot.minY), animations=\(animations)")
                        }
                    }
                }
                if measured == 0 { throw Failure(description: "\(style)/\(phase): no presentation layers sampled") }
            }
        }
            }
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n") + "\nframes: \(directory.path)") }
        return "SidebarRowPresentationChecks passed: all four styles, status completion and arrival, expanded and unfolding; presentation frames stayed in their slots or intentional unfold/reflow envelope; \(directory.path)"
    }
}
