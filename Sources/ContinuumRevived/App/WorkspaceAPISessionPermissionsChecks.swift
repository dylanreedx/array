import AppKit
import ContinuumRevivedCore
import Foundation

/// A session decision passes through the production dispatch and owner, and is
/// reusable by another agent only for the same project and action scope.
@MainActor
func runWorkspaceAPISessionPermissionsChecks() throws {
    struct Failure: Error { let message: String }
    func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
        throw Failure(message: "isolated app support required")
    }
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.delegate.qaAgentSupervisor.stopAll(); f.tearDown() }
    let api = f.api
    let supervisor = f.delegate.qaAgentSupervisor
    _ = supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
    let second = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi,
        model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: f.projectPb, projectRoot: f.pbRoot)
    let foreign = supervisor.spawn(role: nil, prompt: nil, cwd: f.pcRoot, harness: .pi,
        model: "openai-codex/gpt-5.6-sol", thinking: "high", projectId: f.projectPc, projectRoot: f.pcRoot)
    _ = supervisor.setWorkspaceToolsEnabled(agentID: second, true)
    _ = supervisor.setWorkspaceToolsEnabled(agentID: foreign, true)
    // Preserve the existing agent-only choice beside project sharing.
    var agentOnlyPrompts = 0
    var agentOnlyDecision: WorkspaceAPIService.ScopeApprovalDecision = .allowForSession
    let agentOnly = WorkspaceAPIService(runtime: { f.runtime }, canvas: { f.canvas },
        focusBroker: { f.focusBroker }, supervisor: supervisor,
        registryStore: api.registryStoreProvider, epoch: "agent-only-session",
        approvalHandler: { _ in agentOnlyPrompts += 1; return agentOnlyDecision })
    func agentOnlyOpen(_ caller: AgentID) -> Bool {
        if case .result = agentOnly.dispatch(agentId: caller, requestId: UUID().uuidString, op: "artifact.open",
            payload: ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue]) { return true }
        return false
    }
    try expect(agentOnlyOpen(f.agentId) && agentOnlyOpen(f.agentId) && agentOnlyPrompts == 1,
               "agent-only approval performs and reuses the approved action")
    agentOnlyDecision = .deny
    try expect(!agentOnlyOpen(second) && agentOnlyPrompts == 2,
               "agent-only approval never grants a peer in the same project")
    agentOnly.revoke(agentId: f.agentId)
    try expect(!agentOnlyOpen(f.agentId) && agentOnlyPrompts == 3,
               "revocation removes agent-only session authority")
    var promptCount = 0
    api.approvalHandler = { _ in promptCount += 1; return .allowForProjectSession }
    func open(_ agent: AgentID, _ handle: CheckoutHandle) -> WorkspaceAPIService.Reply {
        api.dispatch(agentId: agent, requestId: UUID().uuidString, op: "artifact.open", payload: [
            "relativePath": "notes.md", "checkoutHandle": handle.rawValue,
            "presentation": ["camera": "preserve"]])
    }
    func succeeded(_ reply: WorkspaceAPIService.Reply) -> Bool {
        if case .result = reply { return true }; return false
    }
    try expect(succeeded(open(f.agentId, f.paHandle)), "first approved file actually opens")
    try expect(promptCount == 1, "first action asks once")
    api.approvalHandler = { _ in promptCount += 1; return .deny }
    try expect(succeeded(open(second, f.paHandle)), "another agent in the project reuses session approval")
    try expect(promptCount == 1, "same project/action does not ask twice")
    try expect(!succeeded(open(second, f.pcHandle)), "another target project does not inherit the approval")
    try expect(promptCount == 2, "another target scope reaches approval")
    try expect(!succeeded(open(foreign, f.paHandle)), "a foreign caller project does not inherit the approval")
    try expect(promptCount == 3, "foreign caller reaches approval")
    let inspect = api.dispatch(agentId: second, requestId: UUID().uuidString, op: "agent.inspect",
        payload: ["agentId": foreign.rawValue.uuidString])
    try expect(!succeeded(inspect), "file approval does not authorize transcript inspection")
    try expect(promptCount == 4, "another action reaches approval")

    _ = supervisor.setWorkspaceToolsEnabled(agentID: second, false)
    try expect(!succeeded(open(second, f.paHandle)), "disabled agent cannot use a shared approval")
    _ = supervisor.setWorkspaceToolsEnabled(agentID: second, true)
    try expect(succeeded(open(second, f.paHandle)) && promptCount == 4,
               "session lasts until quit; enabling tools restores approved scope")
    let restarted = WorkspaceAPIService(runtime: { f.runtime }, canvas: { f.canvas },
        focusBroker: { f.focusBroker }, supervisor: supervisor,
        registryStore: api.registryStoreProvider, epoch: "fresh-session",
        approvalHandler: { _ in .deny })
    let afterQuit = restarted.dispatch(agentId: second, requestId: "after-quit", op: "artifact.open",
        payload: ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue])
    try expect(!succeeded(afterQuit) && restarted.approvalPromptCount == 1,
               "a new app session does not inherit a previous session approval")

    let capture = ProcessInfo.processInfo.environment["CONTINUUM_PERMISSION_UI_CAPTURE_DIR"]
    for op in [WorkspaceAPIOp.deviceOpen, .artifactOpen, .agentInspect] {
        let prompt = WorkspaceAPIService.ScopeApprovalPrompt(requestId: "appearance", agentId: f.agentId,
            agentDisplayName: "Preview helper", checkout: f.pbHandle, checkoutDisplayName: "Example project",
            op: op, relativePath: op == .artifactOpen ? "Sources/App.swift" : nil,
            targetAgentDisplayName: op == .agentInspect ? "Build helper" : nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let alert = f.delegate.workspaceToolApprovalAlert(prompt)
            try expect(alert.buttons.map(\.title) == ["Allow Once", "Allow for This Agent Session", "Allow for This Project Session", "Deny"],
                       "production alert presents the session choice")
            if op == .deviceOpen {
                try expect(alert.messageText.contains("simulator") && !alert.messageText.contains("open files")
                           && alert.informativeText.contains("this simulator visit"),
                           "device approval describes the simulator action and Allow Once visit")
            }
            if let capture {
                let directory = URL(fileURLWithPath: capture, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                    styleMask: [.titled], backing: .buffered, defer: false)
                host.appearance = NSAppearance(named: appearance)
                host.orderFrontOffscreenForChecks()
                let window = alert.window
                window.appearance = NSAppearance(named: appearance)
                // Present the production alert so AppKit installs its native
                // materials and button cells, then capture the actual sheet.
                // CheckFocusGuard keeps both titled windows off every display.
                alert.beginSheetModal(for: host) { _ in }
                defer { host.endSheet(window); window.orderOut(nil); host.orderOut(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                window.appearance?.performAsCurrentDrawingAppearance {
                    window.contentView?.needsDisplay = true
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.contentView?.displayIfNeeded()
                    window.displayIfNeeded()
                }
                CATransaction.flush()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                    CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
                    let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw Failure(message: "cannot capture production alert window")
                }
                try png.write(to: directory.appendingPathComponent("\(op.rawValue)-\(name).png"))
            }
        }
    }

    // Allow Once never populates the project session table.
    api.approvalHandler = { _ in promptCount += 1; return .allowOnce }
    let once = api.dispatch(agentId: f.agentId, requestId: UUID().uuidString, op: "agent.inspect",
        payload: ["agentId": foreign.rawValue.uuidString])
    try expect(succeeded(once), "Allow Once performs inspection")
    api.approvalHandler = { _ in promptCount += 1; return .deny }
    let again = api.dispatch(agentId: f.agentId, requestId: UUID().uuidString, op: "agent.inspect",
        payload: ["agentId": foreign.rawValue.uuidString])
    try expect(!succeeded(again) && promptCount == 6, "Allow Once asks again for the next inspection")
}
