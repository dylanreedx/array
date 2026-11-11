import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Drives the mounted preview sidebar and captures only its real application window.
@MainActor
enum SidebarApprovedLiveCaptureChecks {
    static func run(window: NSWindow, inbox: AgentInboxView, directory: URL) async throws {
        let defaults = UserDefaults.standard
        let oldScope = defaults.object(forKey: SidebarActiveIndicatorScope.defaultsKey)
        let oldStyle = defaults.object(forKey: SidebarActiveIndicatorStyle.defaultsKey)
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
        for dark in [true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let appearance = dark ? "dark" : "light"
            for state in ["selected-done-capped", "selected-working-expanded", "all-working-unselected"] {
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
                inbox.openAgentId = state == "all-working-unselected" ? nil : lead
                inbox.reload(rows: [parent])
                inbox.apply(rows: [parent] + helpers,
                    changed: AgentsBoardChangeSet(added: Set(helpers.map(\.id)), updated: [lead], removed: []))
                inbox.restoreParentFolds([lead: true])
                if state == "all-working-unselected" { inbox.clearSelectionForQA() }
                else { _ = inbox.selectRowForQA(id: lead) }
                inbox.layoutViewportForQA()
                try await Task.sleep(for: .milliseconds(300))
                try await capture(appearance + "-" + state)
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
}
