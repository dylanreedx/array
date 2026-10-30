import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

@MainActor
enum ManagedSettingChecks {
    static func expect(_ condition: Bool, _ message: String) throws {
        try ManagedModeChecks.expect(condition, "setting: " + message)
    }
    static func write(_ key: String, _ value: Bool, _ b: WorkspaceAgentReportChecks.Bench) {
        let model = SettingsModel(defaults: b.settings, navKeymap: .resolve(defaults: b.settings, warn: { _ in }))
        let field = SettingsSchema.sections().flatMap(\.fields).first { $0.key == key }!
        model.write(.bool(value), to: field)
    }
    static func run() async throws {
        let b = try ManagedModeChecks.bench("managed-setting")
        let restore = ManagedCodexChecks.runEnvironment(b)
        defer { b.tearDown(); restore() }
        let codex = b.binDir.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "scripts/fixtures/codex-hook-cli.py"), to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .ready, models: [ManagedCodexChecks.model]))
        try expect(AgentManagedModeConfig.enabled(defaults: b.settings)
            && AgentManagedModeConfig.showIndicator(defaults: b.settings), "defaults must be on")
        func spawn(_ harness: AgentHarness, _ model: String) throws -> AgentID {
            let cwd = b.binDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            // Deliberately contradictory legacy input: Settings must win.
            return b.supervisor.spawn(role: nil, prompt: "first", cwd: cwd, harness: harness, mode: .free,
                                      model: model, thinking: AgentModelConfig.defaultThinking)
        }
        let claude = try spawn(.claudeCode, ManagedModeChecks.model)
        let codexID = try spawn(.codex, ManagedCodexChecks.model)
        let pi = try spawn(.pi, WorkspaceAgentReportChecks.model)
        for id in [claude, codexID, pi] { try await ManagedModeChecks.settled(b, id) }
        try expect(b.supervisor.records[claude]?.mode == .managed && b.supervisor.records[codexID]?.mode == .managed,
                   "new leads did not take the default")
        try expect(b.supervisor.records[pi]?.mode == .free, "Pi inherited managed")
        try expect(try ManagedModeChecks.argv(b, claude).contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"), "Claude first launch lacked managed argv")
        let sid = try ManagedCodexChecks.thread(b, codexID)
        try expect(ManagedCodexChecks.rows(b, kind: "hook", session: sid).contains {
            ManagedCodexChecks.output($0)["permissionDecision"] as? String == "deny"
        }, "Codex first launch did not enforce managed hooks")
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate",
            ["task": "helper", "harness": "Claude Code", "model": ManagedModeChecks.model,
             "mode": "managed", "idempotencyKey": UUID().uuidString])
        let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String
        guard let raw, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "setting helper failed: \(reply.reply)")
        }
        let helper = AgentID(rawValue: uuid)
        try await ManagedModeChecks.settled(b, helper)
        try expect(b.supervisor.records[helper]?.mode == .free, "legacy API mode overrode helper policy")
        try expect(!(try ManagedModeChecks.argv(b, helper)).contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"), "helper cannot edit")

        // Both directions during real held turns. Settings writes reach the
        // observer installed by mountWorkspaceSceneAtBoot, never a QA callback.
        for enabled in [false, true] {
            let before = b.supervisor.effectiveMode(for: claude)
            try expect(b.supervisor.send("HOLD", to: claude) && b.supervisor.send("HOLD", to: codexID), "held sends refused")
            let heldCount = enabled ? 2 : 1
            try await AgentPresenceChecks.eventually("held Codex did not reach hooks", timeout: 15) {
                ManagedCodexChecks.rows(b, kind: "held", session: sid).count == heldCount
            }
            let count = ManagedModeChecks.launches(b, claude).count
            write(AgentManagedModeConfig.enabledKey, enabled, b)
            let target: AgentMode = enabled ? .managed : .free
            for id in [claude, codexID] {
                try expect(b.supervisor.records[id]?.mode == target && b.supervisor.isRunning(id), "setting did not retarget a running lead")
                try expect(b.supervisor.effectiveMode(for: id) == before, "setting changed the in-flight mode")
            }
            let hook = try await ManagedModeChecks.hook(b, codexID,
                ["hook_event_name": "PreToolUse", "tool_name": "apply_patch", "tool_input": ["command": "patch"]])
            try expect((hook["permissionDecision"] as? String == "deny") == (before == .managed), "in-flight hook policy changed")
            try Data().write(to: URL(fileURLWithPath: b.supervisor.records[claude]!.cwd).appendingPathComponent("managed-release"))
            try Data().write(to: URL(fileURLWithPath: ManagedCodexChecks.log(b).path + ".release"))
            for id in [claude, codexID] { try await ManagedModeChecks.settled(b, id) }
            try expect(ManagedModeChecks.launches(b, claude).count == count, "setting restarted the held Claude process")
            for id in [claude, codexID] {
                try expect(b.supervisor.send("next", to: id), "next send refused")
                try await ManagedModeChecks.settled(b, id)
                try expect(b.supervisor.effectiveMode(for: id) == target, "next turn did not change policy")
            }
            let args = try ManagedModeChecks.argv(b, claude)
            try expect(args.contains("--resume") && args.contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents") == enabled,
                       "Claude next turn did not resume with target argv")
            let launch = ManagedCodexChecks.rows(b, kind: "launch", session: sid).last!
            try expect((launch["request"] as? [String: Any])?["method"] as? String == "thread/resume", "Codex did not resume")
            let hooks = ManagedCodexChecks.rows(b, kind: "hook", session: sid).filter { $0["pid"] as? Int == launch["pid"] as? Int }
            try expect(hooks.contains { ManagedCodexChecks.output($0)["permissionDecision"] as? String == "deny" } == enabled,
                       "next Codex hook retained old policy")
            try expect(b.supervisor.records[helper]?.mode == .free && b.supervisor.records[pi]?.mode == .free, "toggle changed helper/Pi")
        }
        // Persist a stale target then restore under each opposite setting.
        let store = AgentStore(applicationSupportDirectory: b.binDir.appendingPathComponent("restore"))
        for enabled in [false, true] {
            var record = b.supervisor.records[claude]!
            record.mode = enabled ? .free : .managed
            try store.upsert(record)
            write(AgentManagedModeConfig.enabledKey, enabled, b)
            let fresh = AgentSupervisor(store: store)
            fresh.configureManagedMode(defaults: b.settings)
            fresh.restore()
            try expect(fresh.records[claude]?.mode == (enabled ? .managed : .free), "relaunch failed to reconcile stale target")
            try expect(!fresh.isRunning(claude), "restore launched a turn")
            fresh.stopAll()
        }
        try renderAndCheck(b, claude)
        try UIProbeAppearance.runManagedModeTokenChecks()
        print("Managed setting checks passed: defaults, real Claude/Codex/Pi launch, API helper free, Settings deferred switches both directions, hooks/argv/resume, relaunch, badge visibility and frame fit")
    }

    static func renderAndCheck(_ b: WorkspaceAgentReportChecks.Bench, _ id: AgentID) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var captures: [NSImage] = []
            for width: CGFloat in [640, 320] {
                let (tile, window) = TileChromeCanvasChecks.makeTile(width: width, height: 400, appearance: appearance)
                defer { window.orderOut(nil) }
                tile.attach(agentID: id, supervisor: b.supervisor)
                tile.applyBranchContext(AgentRowContext(agentKind: .managed, checkedOutBranch: "array/managed-mode"))
                tile.wakeChrome()
                tile.layoutSubtreeIfNeeded()
                let header = tile.qaPageZoomHeaderView
                try expect(header.qaManagedFrame != nil, "managed badge missing at \(width)")
                for zoom in [AgentPageZoom.default, AgentPageZoom(percent: 150)] {
                    tile.setPageZoom(zoom); tile.layoutSubtreeIfNeeded()
                    if width == 320 && zoom.percent == 150 {
                        try expect(header.qaManagedFrame == nil, "badge must yield before severe branch truncation")
                    }
                    let bounds = header.bounds.insetBy(dx: -1, dy: -1)
                    try expect(bounds.contains(header.qaBranchFrame), "branch overflow at \(width)/\(zoom.percent)")
                    if let frame = header.qaManagedFrame {
                        try expect(bounds.contains(frame) && frame.minX >= header.qaBranchFrame.maxX, "badge overflow/overlap")
                    } else { try expect(width == 320 && zoom.percent == 150, "badge yielded too early") }
                }
                tile.setPageZoom(.default); tile.layoutSubtreeIfNeeded()
                write(AgentManagedModeConfig.showIndicatorKey, false, b)
                tile.layoutSubtreeIfNeeded()
                try expect(header.qaManagedFrame == nil && b.supervisor.effectiveMode(for: id) == .managed, "hide indicator changed mode or left badge")
                write(AgentManagedModeConfig.showIndicatorKey, true, b)
                write(AgentManagedModeConfig.enabledKey, false, b)
                tile.layoutSubtreeIfNeeded()
                try expect(header.qaManagedFrame == nil, "free mode retained badge")
                write(AgentManagedModeConfig.enabledKey, true, b)
                tile.layoutSubtreeIfNeeded()
                try expect(header.qaManagedFrame != nil, "badge did not return")
                // Preserve the full actionable badge and the branch at the
                // same narrow/150% boundary guarded by 6f72b206.
                tile.applyAwarenessSignal(AgentSignal(id: "managed-fit", kind: .actionRequired,
                    agentID: nil, tileID: tile.tile.id, threadID: nil, occurredAt: Date(), source: .managedRuntime))
                for zoom in [AgentPageZoom.default, AgentPageZoom(percent: 150)] {
                    tile.setPageZoom(zoom); tile.layoutSubtreeIfNeeded()
                    let bounds = header.bounds.insetBy(dx: -1, dy: -1)
                    try expect(bounds.contains(header.qaBranchFrame), "crowded branch overflow")
                    let status = header.subviews.flatMap(\.subviews).compactMap { $0 as? AgentSignalBadgeView }.first!
                    try expect(bounds.contains(status.convert(status.bounds, to: header)), "action badge overflow")
                    if width == 320 { try expect(header.qaManagedFrame == nil, "Managed must yield to action status") }
                }
                tile.applyAwarenessSignal(nil)
                tile.setPageZoom(.default); tile.layoutSubtreeIfNeeded()
                let rendered = try TranscriptViewportClippingChecks.render(tile).image
                let scale = CGFloat(rendered.width) / width
                let crop = rendered.cropping(to: CGRect(x: 0, y: 0, width: rendered.width, height: Int(60 * scale)))!
                captures.append(NSImage(cgImage: crop, size: NSSize(width: width, height: 60)))
            }
            if let path = ProcessInfo.processInfo.environment["MANAGED_BADGE_PNG_DIR"] {
                let image = NSImage(size: NSSize(width: 680, height: 180))
                image.lockFocus()
                SurfaceToken.tileBody.color.nsColor(for: appearance == .aqua ? .light : .dark).setFill()
                NSRect(x: 0, y: 0, width: 680, height: 180).fill()
                captures[0].draw(in: NSRect(x: 20, y: 100, width: 640, height: 60))
                captures[1].draw(in: NSRect(x: 20, y: 20, width: 320, height: 60))
                image.unlockFocus()
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try rep.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("managed-badge-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}
