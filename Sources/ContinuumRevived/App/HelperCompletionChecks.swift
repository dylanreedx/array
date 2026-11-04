import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum HelperCompletionChecks {
    static func runRetries() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper provider retry check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-provider-retry")
        defer { bench.tearDown() }
        let s = bench.supervisor, parent = bench.f.agentId
        var terminalCounts: [AgentID: Int] = [:]
        let observer = s.addDeliveredEventObserver { id, event in
            if case .turnCompleted = event { terminalCounts[id, default: 0] += 1 }
        }
        defer { s.removeDeliveredEventObserver(observer) }
        s.helperProviderRetryDelay = 10_000_000
        s.helperCompletionEnabled = { _ in true }
        var now = Date()
        s.helperCompletionNow = { now }
        let setup = """
                key = os.environ.get("ARRAY_AGENT_ID") or str(os.getpid())
                statefile = os.path.join(os.getcwd(), "retry-" + key + ".json")
                mode, attempt = None, 0
                if os.path.exists(statefile):
                    with open(statefile) as saved:
                        mode, attempt = json.load(saved)
                if not any(line == "Helper turn updates" for line in str(text).splitlines()):
                    for candidate in ["RETRY-SUCCESS", "RETRY-EXHAUST", "RETRY-WORK", "RETRY-RATE", "RETRY-HTTP", "RETRY-HTTP501", "RETRY-STREAM"]:
                        if candidate in str(text):
                            mode = candidate
                if mode:
                    attempt += 1
                    with open(statefile, "w") as saved:
                        json.dump([mode, attempt], saved)
        """
        let end = """
                if mode and (mode == "RETRY-EXHAUST" or mode == "RETRY-WORK" or attempt < 3):
                    error = {"RETRY-WORK": "helper work assertion failed", "RETRY-RATE": "rate limited", "RETRY-HTTP": "HTTP 503", "RETRY-HTTP501": "HTTP 501", "RETRY-STREAM": "stream disconnected"}.get(mode, "serverOverloaded")
                    emit({"type": "turn_end", "message": {"role": "assistant", "stopReason": "error", "errorMessage": error}})
                else:
                    emit({"type": "turn_end", "message": {"role": "assistant"}})
        """
        var script = WorkspaceAgentReportChecks.fakePi
        script = script.replacingOccurrences(of: "        with open(os.path.join(os.getcwd(), \"prompts.log\"), \"a\") as log:", with: setup + "\n        with open(os.path.join(os.getcwd(), \"prompts.log\"), \"a\") as log:")
        script = script.replacingOccurrences(of: "        emit({\"type\": \"turn_end\", \"message\": {\"role\": \"assistant\"}})", with: end)
        try script.write(to: bench.binDir.appendingPathComponent("pi"), atomically: true, encoding: .utf8)
        for (marker, expectedRetries, expectedOutcome) in [("RETRY-SUCCESS", 2, AgentTerminalOutcome.succeeded), ("RETRY-EXHAUST", 2, .failed), ("RETRY-WORK", 0, .failed), ("RETRY-RATE", 2, .succeeded), ("RETRY-HTTP", 2, .succeeded), ("RETRY-HTTP501", 2, .succeeded), ("RETRY-STREAM", 2, .succeeded)] {
            let child = try bench.delegate(marker)
            let settled = await waitUntil(timeout: 20, pollInterval: 0.02) { !s.isRunning(child) && s.records[child]?.latestTerminalEvent != nil }
            try HelperGuardChecks.expect(settled, "retry helper did not settle")
            try HelperGuardChecks.expect((s.helperProviderRetryCounts[child] ?? 0) == expectedRetries, "\(marker): wrong retry count")
            try HelperGuardChecks.expect(terminalCounts[child] == 1, "intermediate retry terminal reached production subscribers")
            try HelperGuardChecks.expect(s.records[child]?.latestTerminalEvent?.outcome == expectedOutcome, "\(marker): wrong final outcome")
            now.addTimeInterval(9)
            await s.flushHelperCompletions()
            let idle = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(parent) }
            try HelperGuardChecks.expect(idle, "lead did not finish update")
            let log = try String(contentsOf: URL(fileURLWithPath: s.records[parent]!.cwd).appendingPathComponent("prompts.log"), encoding: .utf8)
            let updates = log.split(separator: "\n").compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }.filter { $0.components(separatedBy: "\n").contains("Helper turn updates") && $0.contains(child.rawValue.uuidString) }
            try HelperGuardChecks.expect(updates.count == 1, "intermediate failure leaked or final wake repeated")
            if marker == "RETRY-EXHAUST" { try HelperGuardChecks.expect(updates[0].contains("failed after 2 retries: serverOverloaded"), "exhausted retries missing from report") }
            if marker == "RETRY-SUCCESS" { try HelperGuardChecks.expect(updates[0].contains("succeeded") && !updates[0].contains("failed:"), "successful retry was reported failed") }
        }
        s.helperProviderRetryDelay = 5_000_000_000
        let stopped = try bench.delegate("RETRY-EXHAUST-stop")
        let waiting = await waitUntil(timeout: 15, pollInterval: 0.02) { s.helperProviderRetryCounts[stopped] == 1 }
        try HelperGuardChecks.expect(waiting && s.isRunning(stopped), "retry pause was not held open")
        s.stop(stopped)
        try await Task.sleep(nanoseconds: 100_000_000)
        try HelperGuardChecks.expect(!s.isRunning(stopped) && s.helperProviderRetryCounts[stopped] == 1
            && s.records[stopped]?.latestTerminalEvent?.outcome == .interrupted, "Stop did not cancel pending retry")
    }
    static func runSetting() async throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-wake-setting")
        defer { bench.tearDown() }
        let s = bench.supervisor, id = bench.f.agentId
        let before = s.records[id]!
        try HelperGuardChecks.expect(!s.wakesForHelperCompletion(id), "plain agent default must be off")
        let managedStore = AgentStore(applicationSupportDirectory: bench.f.tempRoot.appendingPathComponent("managed-setting-default"))
        var managed = before
        managed.harness = .codex
        managed.mode = .managed
        try managedStore.upsert(managed)
        let managedSupervisor = AgentSupervisor(store: managedStore)
        _ = managedSupervisor.restore()
        managedSupervisor.configureManagedMode(defaults: bench.settings)
        try HelperGuardChecks.expect(managedSupervisor.wakesForHelperCompletion(id), "Managed lead default must be on")
        try HelperGuardChecks.expect(s.setHelperCompletionWake(true, for: id) && s.wakesForHelperCompletion(id), "plain agent could not enable helper wakes")
        try HelperGuardChecks.expect(s.records[id] == before, "wake preference replaced or changed the agent record")
        let restored = AgentSupervisor(store: AgentStore(applicationSupportDirectory: bench.f.tempRoot.appendingPathComponent("setting-restore")))
        restored.configureManagedMode(defaults: bench.settings)
        try HelperGuardChecks.expect(restored.wakesForHelperCompletion(id), "preference did not survive supervisor recreation")
        bench.f.delegate.wireCanvasCallbacks(bench.f.canvas)
        try bench.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: bench.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        bench.f.delegate.qaInstallWorkspaceSidebar(sidebar)
        bench.f.delegate.qaRefreshAgentSurfaces()
        s.configureHelperWakeMenu(sidebar.agentInbox)
        try HelperGuardChecks.expect(sidebar.agentInbox.openRowMenuForQA(clickedRowId: id.rawValue), "lead menu did not open")
        try HelperGuardChecks.expect(sidebar.agentInbox.rowMenuTitlesForQA.contains("Wake me when helpers finish"), "wake setting absent from lead menu")
        guard let list = sidebar.agentInbox.rowMenuRenderingForQA else { throw WorkspaceAgentReportChecks.Failure(description: "no choice menu to render") }
        list.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            list.appearance = NSAppearance(named: appearance)
            list.layoutSubtreeIfNeeded()
            guard let rep = list.bitmapImageRepForCachingDisplay(in: list.bounds) else { throw WorkspaceAgentReportChecks.Failure(description: "choice menu render unavailable") }
            list.cacheDisplay(in: list.bounds, to: rep)
            let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("array-scratch/lead-wakeups/setting-\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: out)
        }
        try HelperGuardChecks.expect(sidebar.agentInbox.pickRowMenuItemForQA(id: "helper-completion-wake"), "wake preference action did not route")
        try HelperGuardChecks.expect(!s.wakesForHelperCompletion(id), "explicit off ignored")
        try HelperGuardChecks.expect(s.records[id]?.harness == before.harness && s.records[id]?.mode == before.mode, "menu action changed harness or mode")
    }

    static func runMessages() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper message check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-message-result")
        defer { bench.tearDown() }
        let s = bench.supervisor, parent = bench.f.agentId
        let child = try bench.delegate("initial")
        let idle = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(child) && s.records[child]?.latestTerminalEvent != nil }
        try HelperGuardChecks.expect(idle, "initial helper did not settle")
        let config = try bench.configuration(for: parent)
        for (index, outcome) in [TurnOutcome.completed, .failed, .interrupted].enumerated() {
            let handle = "message-result-\(index)"
            let reply = bench.f.api.dispatch(agentId: parent, requestId: handle, op: "agent.message", payload: [
                "agentId": child.rawValue.uuidString, "text": "HOLD-message-\(index)", "idempotencyKey": handle])
            guard case let .result(result) = reply, result["delivery"]?.string == "delivered" else {
                throw WorkspaceAgentReportChecks.Failure(description: "message failed: \(reply)")
            }
            // The new handle must not inherit the preceding turn's result.
            let before = bench.f.api.dispatch(agentId: parent, requestId: UUID().uuidString, op: "operation.get", payload: ["operationId": handle])
            guard case let .result(beforeResult) = before else { throw WorkspaceAgentReportChecks.Failure(description: "operation refused") }
            try HelperGuardChecks.expect(beforeResult["childResult"] == nil, "new message inherited old result")
            s.qaDeliver(.turnCompleted(threadId: "message", turnId: handle, outcome: outcome, errorMessage: outcome == .failed ? "helper work error" : nil), to: child)
            // The handle settles independently of a later active turn.
            let waited = try await WorkspaceAgentReportChecks.call(config, "wait_agents", ["handles": [handle], "timeoutSeconds": 1])
            let entries = (waited.reply["result"] as? [String: Any])?["agents"] as? [[String: Any]]
            let expected = outcome == .completed ? "completed" : (outcome == .failed ? "failed" : "interrupted")
            try HelperGuardChecks.expect(entries?.first?["status"] as? String == expected, "message handle did not settle as \(expected): \(waited.reply)")
            try Data().write(to: URL(fileURLWithPath: s.records[child]!.cwd).appendingPathComponent("release.flag"))
            let done = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(child) }
            try HelperGuardChecks.expect(done, "helper did not release")
            let file = SpawnResultFile.read(parentCwd: s.records[parent]!.cwd, handle: handle)
            try HelperGuardChecks.expect(file?.status.rawValue == expected, "later terminal overwrote a message handle")
        }
    }
    static func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper completion check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-completion")
        defer { bench.tearDown() }
        let script = WorkspaceAgentReportChecks.fakePi.replacingOccurrences(
            of: "if \"HOLD\" in json.dumps(text):",
            with: "if \"HOLD\" in json.dumps(text) and not any(line == \"Helper turn updates\" for line in str(text).splitlines()):")
        try script.write(to: bench.binDir.appendingPathComponent("pi"), atomically: true, encoding: .utf8)
        let s = bench.supervisor, parent = bench.f.agentId
        var now = Date()
        s.helperCompletionNow = { now }
        s.helperCompletionEnabled = { _ in true }
        func finish(_ child: AgentID, _ turn: String, _ outcome: TurnOutcome = .completed) {
            s.qaDeliver(.turnCompleted(threadId: "fixture", turnId: turn, outcome: outcome, errorMessage: outcome == .failed ? "work failed" : nil), to: child)
        }
        let child = try bench.delegate("HOLD-first")
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) { s.isRunning(child) }
        try HelperGuardChecks.expect(started, "helper did not start")
        _ = s.fileReport(.init(summary: "WAKE-REPORT",
            findings: Array(repeating: .init(level: .note, text: String(repeating: "detail ", count: 55)), count: 6),
            detailsPath: "WAKE-DETAILS"), for: child)
        finish(child, "first")
        now.addTimeInterval(7)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(!s.isRunning(parent), "completion fired before eight seconds")
        now.addTimeInterval(2)
        await s.flushHelperCompletions()
        let cwd = URL(fileURLWithPath: s.records[parent]!.cwd)
        func log() -> String { (try? String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        func wakeCount() -> Int {
            log().split(separator: "\n").compactMap { line -> String? in
                try? JSONDecoder().decode(String.self, from: Data(line.utf8))
            }.filter { $0.components(separatedBy: "\n").contains("Helper turn updates") }.count
        }
        let received = await waitUntil(timeout: 15, pollInterval: 0.02) { log().contains("WAKE-REPORT") && !s.isRunning(parent) }
        try HelperGuardChecks.expect(received, "idle lead did not receive helper report")
        try HelperGuardChecks.expect(log().contains("WAKE-DETAILS") && log().components(separatedBy: "detail ").count - 1 == 330,
            "structured report was truncated in the lead update")
        finish(child, "first")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(log().components(separatedBy: "WAKE-REPORT").count - 1 == 1, "duplicate completion delivered")
        try HelperGuardChecks.expect(s.send("HOLD-parent", to: parent), "parent did not start")
        let children = try (0..<3).map { try bench.delegate("HOLD-group-\($0)") }
        for (i, c) in children.enumerated() { finish(c, "group-\(i)", i == 0 ? .failed : .interrupted) }
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let updates = s.queuedMessages(for: parent).filter { $0.text.contains("Helper turn updates") }
        try HelperGuardChecks.expect(updates.count == 1 && children.allSatisfy { updates[0].text.contains($0.rawValue.uuidString) }, "busy lead did not queue one grouped update")
        // Regressed in 4fa6e039: composer admission inserted U+200B inside
        // the host envelope. Check the actual queued payload, then the live
        // document after the queue drains, rather than just matching its body.
        guard case let .agentMessage(queuedPayload) = AgentMessageEnvelope.classify(updates[0].text) else {
            throw WorkspaceAgentReportChecks.Failure(description: "busy helper completion lost structured agent attribution")
        }
        try HelperGuardChecks.expect(queuedPayload.senderAgentID == children[0].rawValue && queuedPayload.text.hasPrefix("Helper turn updates\n"),
            "queued completion lost sender or body")
        // .43: inspect the production queue row WHILE the lead is busy,
        // before draining. Delivered-card assertions alone missed this surface.
        let pendingState = s.queueRailState(for: parent)
        var pendingPreviews: [String] = []
        for theme in [TokenTheme.light, .dark] {
            let rail = ComposerQueuedMessageRailView(frame: .zero)
            rail.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
            rail.setState(pendingState)
            rail.frame = NSRect(x: 0, y: 0, width: 720, height: rail.railHeight)
            let window = NSWindow(contentRect: rail.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = rail.appearance
            window.backgroundColor = SurfaceToken.tileBody.color.nsColor(for: theme)
            let surface = NSView(frame: rail.frame)
            surface.wantsLayer = true
            surface.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(for: theme)
            surface.addSubview(rail)
            window.contentView = surface
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            surface.layoutSubtreeIfNeeded()
            guard let row = rail.qaRow(for: updates[0].id) else {
                throw WorkspaceAgentReportChecks.Failure(description: "busy completion queue row is missing")
            }
            pendingPreviews.append(row.qaText)
            if let directory = ProcessInfo.processInfo.environment["CONTINUUM_QUEUED_MESSAGE_CAPTURE"], !directory.isEmpty {
                let out = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let phase = ProcessInfo.processInfo.environment["CONTINUUM_QUEUE_CAPTURE_PHASE"] == "before" ? "before" : "after"
                guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
                    throw WorkspaceAgentReportChecks.Failure(description: "queued row capture unavailable")
                }
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw WorkspaceAgentReportChecks.Failure(description: "queued row PNG unavailable")
                }
                try png.write(to: out.appendingPathComponent("queued-\(phase)-\(theme == .light ? "light" : "dark").png"))
            }
        }
        try HelperGuardChecks.expect(s.isRunning(parent) && s.queuedMessages(for: parent).first?.text == updates[0].text,
            "preview changed queued transport or drained the busy lead")
        try HelperGuardChecks.expect(pendingPreviews == Array(repeating: "\(queuedPayload.senderName) · Helper turn updates", count: 2),
            "busy queue preview must show sender and clean summary, got \(pendingPreviews)")
        // The same row handles shared attribution and ordinary typed text.
        let sharedText = "From Mira\n\n---\nReview the failing leg.\nMore details."
        let plainText = "Explain <array-agent-message>\nand keep this text."
        let typedEnvelope = AgentMessageEnvelope.neutralizedUserText(updates[0].text)
        for (text, expected) in [(sharedText, "Mira · Review the failing leg."),
                                 (plainText, "Explain <array-agent-message> and keep this text."),
                                 (typedEnvelope, typedEnvelope.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " "))] {
            let rail = ComposerQueuedMessageRailView(frame: .zero)
            var state = ComposerQueueRailState.empty
            state.queued = [.init(id: UUID(), text: text, attachmentCount: 0, kind: .queued)]
            rail.setState(state)
            try HelperGuardChecks.expect(rail.qaItemRows.first?.qaText == expected,
                "shared or typed queue preview changed authorship/content")
        }
        let typed = AgentMessageEnvelope.neutralizedUserText(updates[0].text)
        try HelperGuardChecks.expect(AgentMessageEnvelope.classify(typed) == .prompt,
            "typed envelope spoof protection was weakened")
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(s.queuedMessages(for: parent).filter { $0.text.contains("Helper turn updates") }.count == 1, "queued update repeated")
        let end = Date().addingTimeInterval(20)
        while Date() < end && (s.isRunning(parent) || !s.queuedMessages(for: parent).isEmpty) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try HelperGuardChecks.expect(wakeCount() == 2, "group did not deliver once after busy turn; queued=\(s.queuedMessages(for: parent).count), running=\(s.isRunning(parent)), log=\(log())")
        let wakeBlocks = s.transcriptDocumentProjection(for: parent)?.entries.flatMap(\.blocks).filter { block in
            if case let .agentMessage(payload) = block.payload { return payload.text.hasPrefix("Helper turn updates\n") }
            return false
        } ?? []
        try HelperGuardChecks.expect(wakeBlocks.count == 2,
            "idle and busy completion updates must both project as agent-message cards")
        for block in s.transcriptDocumentProjection(for: parent)?.entries.flatMap(\.blocks) ?? [] {
            if case let .paragraph(inlines) = block.payload {
                try HelperGuardChecks.expect(!String(describing: inlines).contains("array-agent-message"),
                    "raw completion envelope reached user prose")
            }
        }
        // Session restores must retain the same attribution across all three
        // harness formats, using the actual host-queued completion text.
        func jsonLine(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let restored: [(String, RehydratedTranscript)] = [
            ("claude", ClaudeSessionTranscriptReader.parse(lines: [try jsonLine([
                "type": "user", "isSidechain": false,
                "message": ["role": "user", "content": updates[0].text]])], threadId: "completion-claude")),
            ("codex", CodexSessionTranscriptReader.parse(lines: [try jsonLine([
                "type": "event_msg", "payload": ["type": "user_message", "message": updates[0].text]])], threadId: "completion-codex")),
            ("pi", PiSessionTranscriptReader.parse(lines: [try jsonLine([
                "type": "message", "message": ["role": "user", "content": [["type": "text", "text": updates[0].text]]]])], threadId: "completion-pi")),
        ]
        for (harness, transcript) in restored {
            var projection = AgentTranscriptProjection(threadId: "completion-restore-\(harness)")
            for step in transcript.steps {
                if case let .userPrompt(text) = step { projection.appendUserPrompt(text) }
            }
            let blocks = projection.document.entries.flatMap(\.blocks)
            try HelperGuardChecks.expect(blocks.count == 1 && blocks[0].payload == .agentMessage(queuedPayload),
                "\(harness) completion restore lost its structured message")
        }
        // Use the established renderer for the blocks emitted by real queue
        // delivery. Both appearances must name the helper and show its body.
        for theme in [TokenTheme.light, .dark] {
            let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: theme)
            let renderer = AgentMessageRenderer()
            for (index, block) in wakeBlocks.enumerated() {
                let view = renderer.makeView()
                let height = renderer.measure(block: block, width: 560, context: context)
                view.frame = NSRect(x: 0, y: 0, width: 560, height: height)
                view.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                renderer.update(view: view, block: block, context: context)
                view.layoutSubtreeIfNeeded()
                guard let card = view as? AgentMessageCardView,
                      case let .agentMessage(payload) = block.payload else {
                    throw WorkspaceAgentReportChecks.Failure(description: "completion did not render an agent-message card")
                }
                try HelperGuardChecks.expect(height > 0 && card.payload == payload
                    && card.senderButton.nameLabel.stringValue.contains(payload.senderName)
                    && card.bodyLabel.stringValue == payload.text,
                    "completion card lost sender or body in \(theme)")
                if let directory = ProcessInfo.processInfo.environment["CONTINUUM_AGENT_MESSAGE_CAPTURE"], !directory.isEmpty {
                    let out = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = view.appearance
                    window.backgroundColor = context.tokens.bodySurface.color.nsColor(for: theme)
                    view.wantsLayer = true
                    view.layer?.backgroundColor = context.tokens.bodySurface.color.cgColor(for: theme)
                    window.contentView = view
                    window.orderFrontOffscreenForChecks()
                    defer { window.orderOut(nil) }
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw WorkspaceAgentReportChecks.Failure(description: "completion card capture unavailable")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw WorkspaceAgentReportChecks.Failure(description: "completion card PNG unavailable")
                    }
                    let name = "helper-completion-\(index == 0 ? "idle" : "busy")-\(theme == .light ? "light" : "dark").png"
                    let destination = out.appendingPathComponent(name)
                    try png.write(to: destination)
                    print("helper-completion-check: capture \(destination.path)")
                }
            }
        }
        let stopped = try bench.delegate("HOLD-stop")
        s.stop(stopped)
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let stopDelivered = await waitUntil(timeout: 15, pollInterval: 0.02) { wakeCount() == 3 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(stopDelivered, "stopped helper did not wake lead")
        s.helperCompletionEnabled = { _ in false }
        finish(child, "off")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(wakeCount() == 3, "disabled lead was woken")
    }
}
