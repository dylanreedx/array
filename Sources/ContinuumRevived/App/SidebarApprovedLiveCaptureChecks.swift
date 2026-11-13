import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Drives the mounted preview sidebar and captures only its real application window.
@MainActor
enum SidebarApprovedLiveCaptureChecks {
    static func run(window: NSWindow, inbox: AgentInboxView, directory: URL) async throws {
        let defaults = UserDefaults.standard
        // Restore what is PERSISTED, never what `object(forKey:)` resolves: a launch
        // argument such as `-continuum.sidebar.activeAgentScope selected` resolves
        // through the argument domain, and writing it back made it permanent.
        let persisted = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let oldScope = persisted[SidebarActiveIndicatorScope.defaultsKey]
        let oldStyle = persisted[SidebarActiveIndicatorStyle.defaultsKey]
        defer {
            defaults.set(oldScope, forKey: SidebarActiveIndicatorScope.defaultsKey)
            defaults.set(oldStyle, forKey: SidebarActiveIndicatorStyle.defaultsKey)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox.setScope(.all)
        inbox.foldsUntouchedGroups = false
        inbox.prefersReducedMotion = { false }
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.minX + 40,
                y: max(screen.minY + 40, screen.maxY - window.frame.height - 40)))
        }
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        var paths: [String] = []
        func capture(_ name: String) async throws {
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(200))
            let path = directory.appendingPathComponent(name + ".png").path
            let request: [String: Any] = ["windowNumber": window.windowNumber,
                "pid": ProcessInfo.processInfo.processIdentifier, "path": path, "name": name]
            try JSONSerialization.data(withJSONObject: request).write(
                to: directory.appendingPathComponent("pending-capture.json"), options: .atomic)
            let acknowledgment = directory.appendingPathComponent(name + ".captured")
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: acknowledgment.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: path),
                  FileManager.default.fileExists(atPath: acknowledgment.path) else {
                throw NSError(domain: "SidebarLiveCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Window capture acknowledgment missing: " + path])
            }
            paths.append(path)
        }
        if ProcessInfo.processInfo.environment["ARRAY_SIDEBAR_FOLD_CAPTURE"] == "1" {
            try await foldSequence(window: window, inbox: inbox, capture: capture)
            try paths.joined(separator: "\n").write(to: directory.appendingPathComponent("live-captures.txt"), atomically: true, encoding: .utf8)
            return
        }
        let truthCapture = ProcessInfo.processInfo.environment["ARRAY_SIDEBAR_TRUTH_CAPTURE"] == "1"
        let motionCapture = ProcessInfo.processInfo.environment["ARRAY_DUPLEX_MOTION_CAPTURE"] == "1"
        let states = truthCapture
            ? ["selected-working-expanded", "selected-working-collapsed", "selected-working-helper"]
            : ["selected-done-capped", "selected-working-expanded", "all-working-unselected"]
        for dark in (motionCapture ? [true] : [true, false]) {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let appearance = dark ? "dark" : "light"
            for state in (motionCapture ? ["selected-working-expanded"] : states) {
                let lead = UUID()
                let now = Date()
                let parent = AgentInboxRow(id: lead, title: "Further Sidebar Improvements", projectName: "Array",
                    state: .working, branch: "array/integration", createdAt: now, identityColor: "blue")
                let done = state == "selected-done-capped"
                let helpers = (0..<(done ? 1 : 2)).map { index in
                    AgentInboxRow(id: UUID(), title: index == 0 ? "Fix sidebar agent row styling" : "Compact sidebar header and controls",
                        state: done ? .ready : .working, lastActiveAt: now.addingTimeInterval(done ? -10800 : 0),
                        depth: 1, createdAt: now.addingTimeInterval(-14400 + Double(index)), parentId: lead,
                        terminalEvent: done ? AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded,
                            endedAt: now.addingTimeInterval(-10800)) : nil)
                }
                defaults.set("duplex", forKey: SidebarActiveIndicatorStyle.defaultsKey)
                defaults.set(state == "all-working-unselected" ? "working" : "selected", forKey: SidebarActiveIndicatorScope.defaultsKey)
                for key in [SidebarActiveIndicatorStyle.defaultsKey, SidebarActiveIndicatorScope.defaultsKey] {
                    NotificationCenter.default.post(name: SettingChangeEvent.name(for: SettingID(rawValue: key)), object: nil)
                }
                inbox.openAgentId = state == "all-working-unselected" ? nil
                    : (state == "selected-working-helper" ? helpers[0].id : lead)
                inbox.reload(rows: [parent])
                inbox.apply(rows: [parent] + helpers,
                    changed: AgentsBoardChangeSet(added: Set(helpers.map(\.id)), updated: [lead], removed: []))
                inbox.restoreParentFolds([lead: state != "selected-working-collapsed"])
                if state == "all-working-unselected" { inbox.clearSelectionForQA() }
                else { _ = inbox.selectRowForQA(id: state == "selected-working-helper" ? helpers[0].id : lead) }
                inbox.layoutViewportForQA()
                try await Task.sleep(for: .milliseconds(300))
                if motionCapture {
                    func lights(_ view: NSView) -> [InboxExpandedGroupLight] {
                        ((view as? InboxExpandedGroupLight).map { [$0] } ?? []) + view.subviews.flatMap(lights)
                    }
                    let layers = lights(inbox).flatMap(\.renderedLayersForChecks).filter { $0.animation(forKey: "group.focus") != nil }
                    let saved = layers.map { layer in ["startPoint", "endPoint"].map { layer.animation(forKey: "group.travel." + $0) } }
                    for old in [true, false] {
                        for bottom in [false, true] {
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            for (index, layer) in layers.enumerated() {
                                let phase = bottom ? 2.0 : 0.0
                                for (part, key) in ["startPoint", "endPoint"].enumerated() {
                                    layer.removeAnimation(forKey: "group.travel." + key)
                                    if !old, let animation = saved[index][part] {
                                        layer.add(animation, forKey: "group.travel." + key)
                                    }
                                }
                                layer.speed = 0
                                layer.timeOffset = (layer.animation(forKey: "group.focus")?.beginTime ?? 0) + phase
                            }
                            CATransaction.commit()
                            try await capture((old ? "old" : "new") + (bottom ? "-bottom" : "-top"))
                        }
                    }
                    continue
                }
                try await capture(appearance + "-" + state)
                if truthCapture { continue }
                inbox.toggleCollapse(parentId: lead)
                if state != "all-working-unselected" { _ = inbox.selectRowForQA(id: lead) }
                inbox.layoutViewportForQA()
                inbox.foldMotionForQA.holdForCaptureForQA()
                let frozen = inbox.foldMotionForQA.coveredViewsForQA.compactMap(\.layer)
                for layer in frozen {
                    let time = layer.convertTime(CACurrentMediaTime() + 0.04, from: nil)
                    layer.speed = 0
                    layer.timeOffset = time
                }
                try await capture(appearance + "-" + state + "-mid-fold")
                inbox.foldMotionForQA.cancel()
                for layer in frozen { layer.speed = 1; layer.timeOffset = 0 }
            }
        }
        try paths.joined(separator: "\n").write(to: directory.appendingPathComponent("live-captures.txt"), atomically: true, encoding: .utf8)
    }

    /// A running lead collapsed and expanded in the live window, under whatever
    /// "Apply active style to" this instance resolves (the default, or a launch
    /// argument). The row click and both fold presses go through `NSApp.sendEvent`;
    /// the open agent is then set as the host sets it once it has focused the tile.
    static func foldSequence(window: NSWindow, inbox: AgentInboxView,
                             capture: (String) async throws -> Void) async throws {
        let scope = SidebarActiveIndicatorScope.resolve(in: .standard).rawValue
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
        }
        func press(_ point: NSPoint) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                    throw NSError(domain: "SidebarFoldCapture", code: 1)
                }
                return event
            }
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            NSApp.sendEvent(try event(.leftMouseDown))
        }
        for dark in [true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let prefix = "\(scope)-\(dark ? "dark" : "light")"
            let lead = UUID(), now = Date()
            let parent = AgentInboxRow(id: lead, title: "Further Sidebar Improvements", projectName: "Array",
                state: .working, branch: "array/integration", createdAt: now, identityColor: "blue")
            let helpers = [("Fix sidebar agent row styling", true), ("Compact sidebar header and controls", true),
                           ("Audit the fold witnesses", false)].enumerated().map { index, item in
                AgentInboxRow(id: UUID(), title: item.0, state: item.1 ? .working : .ready,
                    lastActiveAt: now.addingTimeInterval(item.1 ? 0 : -600), depth: 1,
                    createdAt: now.addingTimeInterval(-3600 + Double(index)), parentId: lead)
            }
            inbox.openAgentId = nil
            inbox.reload(rows: [parent])
            inbox.apply(rows: [parent] + helpers,
                changed: AgentsBoardChangeSet(added: Set(helpers.map(\.id)), updated: [lead], removed: []))
            inbox.restoreParentFolds([lead: true])
            inbox.layoutViewportForQA()
            try await Task.sleep(for: .milliseconds(300))
            guard let leadCell = inbox.cellForQA(id: lead) else { throw NSError(domain: "SidebarFoldCapture", code: 2) }
            let y = leadCell.isFlipped ? 9 : leadCell.bounds.height - 9
            try press(leadCell.convert(NSPoint(x: leadCell.bounds.width * 0.55, y: y), to: nil))
            inbox.openAgentId = lead
            inbox.layoutViewportForQA()
            try await capture(prefix + "-1-before")
            for (step, name) in [(2, "collapse"), (4, "expand")] {
                inbox.layoutViewportForQA()
                guard let cell = inbox.cellForQA(id: lead),
                      let control = descendants(cell, InboxSwarmFoldControl.self).first(where: { !$0.isHidden }) else {
                    throw NSError(domain: "SidebarFoldCapture", code: 3)
                }
                try press(control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil))
                inbox.foldMotionForQA.holdForCaptureForQA()
                let frozen = inbox.foldMotionForQA.coveredViewsForQA.compactMap(\.layer)
                for layer in frozen {
                    let time = layer.convertTime(CACurrentMediaTime() + 0.04, from: nil)
                    layer.speed = 0
                    layer.timeOffset = time
                }
                try await capture(prefix + "-\(step)-\(name)-mid-fold")
                inbox.foldMotionForQA.cancel()
                for layer in frozen { layer.speed = 1; layer.timeOffset = 0 }
                inbox.layoutViewportForQA()
                try await capture(prefix + "-\(step + 1)-after-\(name)")
            }
        }
    }
}
