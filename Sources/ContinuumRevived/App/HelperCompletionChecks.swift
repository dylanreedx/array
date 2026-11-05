import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum HelperCompletionChecks {
    static func isCompletionMessage(_ text: String) -> Bool {
        let messages: [AgentMessagePayload]
        switch AgentMessageEnvelope.classify(text) {
        case .agentMessage(let message): messages = [message]
        case .agentMessages(let batch): messages = batch
        default: return false
        }
        return messages.allSatisfy {
            guard let first = $0.text.split(whereSeparator: \.isNewline).first else { return false }
            return first == "Helper turn updates" || first.contains(" finished: ")
        }
    }

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
                if not any((" finished: " in line and not line.startswith("<")) or line == "Helper turn updates" for line in str(text).splitlines()):
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
            func receivedUpdates() -> [String] {
                let log = (try? String(contentsOf: URL(fileURLWithPath: s.records[parent]!.cwd)
                    .appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
                return log.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(String.self, from: Data($0.utf8))
                }.filter { text in
                    guard isCompletionMessage(text) else { return false }
                    switch AgentMessageEnvelope.classify(text) {
                    case .agentMessage(let message): return message.senderAgentID == child.rawValue
                    case .agentMessages(let messages): return messages.contains { $0.senderAgentID == child.rawValue }
                    default: return false
                    }
                }
            }
            let received = await waitUntil(timeout: 15, pollInterval: 0.02) {
                !s.isRunning(parent) && s.queuedMessages(for: parent).isEmpty && receivedUpdates().count == 1
            }
            let updates = receivedUpdates()
            try HelperGuardChecks.expect(received && updates.count == 1,
                "retry completion must arrive once and finish draining; received \(updates.count)")
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
    static func runDeliveryLedger() async throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-delivery-ledger")
        defer { bench.tearDown() }
        let s = bench.supervisor, parent = bench.f.agentId
        let cwd = s.records[parent]!.cwd
        var now = Date()
        s.helperCompletionNow = { now }
        s.helperCompletionEnabled = { _ in true }
        let config = try bench.configuration(for: parent)
        let coalescingPeer = try bench.delegate("HOLD-coalescing-peer")
        let peerReady = await waitUntil(timeout: 15, pollInterval: 0.02) { s.isRunning(coalescingPeer) }
        try HelperGuardChecks.expect(peerReady, "idle coalescing peer did not start")
        func settle(_ marker: String) async throws -> AgentID {
            let child = try bench.delegate(marker)
            let idle = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(child) && s.records[child]?.latestTerminalEvent != nil }
            try HelperGuardChecks.expect(idle, "ledger helper did not settle")
            return child
        }
        func wakes() -> [String] {
            let log = (try? String(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
            return log.split(separator: "\n").compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
                .filter { isCompletionMessage($0) }
        }
        var failures: [String] = []
        // Collect via production operation.get, then flush beyond eight seconds.
        let collected = try await settle("ledger-collected")
        let handle = s.records[collected]!.spawnResultHandle!
        let reply = bench.f.api.dispatch(agentId: parent, requestId: "ledger-get", op: "operation.get", payload: ["operationId": handle])
        guard case let .result(result) = reply else { throw WorkspaceAgentReportChecks.Failure(description: "ledger get refused") }
        guard let first = result["childResult"]?.object else {
            throw WorkspaceAgentReportChecks.Failure(description: "collection omitted result")
        }
        try HelperGuardChecks.expect(first["status"]?.string == "completed"
            && first["finalText"]?.string?.contains(WorkspaceAgentReportChecks.childFinalText) == true,
            "first collection must carry the full result")
        guard let receipt = first["deliveryReceipt"]?.string else {
            throw WorkspaceAgentReportChecks.Failure(description: "collection receipt missing")
        }
        let ack = bench.f.api.dispatch(agentId: parent, requestId: "ledger-get-ack", op: "operation.get",
            payload: ["operationId": handle, "deliveryReceipt": receipt, "acknowledgeDelivery": true])
        guard case .result = ack else { throw WorkspaceAgentReportChecks.Failure(description: "collection ack refused") }
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try await Task.sleep(nanoseconds: 100_000_000)
        if !wakes().isEmpty || !s.queuedMessages(for: parent).isEmpty {
            failures.append("collection-first: collected helper was delivered again by wake")
            print("helper-completion-check: collection-first FAIL")
        } else { print("helper-completion-check: collection-first PASS") }
        _ = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(parent) }
        let beforeWake = wakes().count

        // Never-waited positive control: one wake, followed by a compact MCP answer.
        let woken = try await settle("ledger-woken")
        let wakeHandle = s.records[woken]!.spawnResultHandle!
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let delivered = await waitUntil(timeout: 15, pollInterval: 0.02) { wakes().count == beforeWake + 1 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(delivered, "uncollected helper did not wake once")
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(wakes().count == beforeWake + 1, "positive-control wake repeated")
        let waited = try await WorkspaceAgentReportChecks.call(config, "wait_agents", ["handles": [wakeHandle], "timeoutSeconds": 1])
        let entries = (waited.reply["result"] as? [String: Any])?["agents"] as? [[String: Any]]
        let entry = entries?.first
        if entry?["status"] as? String != "already_delivered" || entry?["report"] != nil || entry?["finalText"] != nil {
            failures.append("wake-first: wait_agents repeated full result")
            print("helper-completion-check: wake-first FAIL")
        } else { print("helper-completion-check: wake-first PASS") }
        print("helper-completion-check: never-waits positive control PASS")
        try HelperGuardChecks.expect(failures.isEmpty, failures.joined(separator: "; "))
        let file = SpawnResultFile.read(parentCwd: cwd, handle: wakeHandle)
        try HelperGuardChecks.expect(file?.deliveredVia != nil, "wake mark missing in spawn-result file")
        print("helper-completion-check: wake-first MCP already_delivered and never-waits positive control PASS")

        // Refresh same-turn content up to durable admission. This catches a
        // report at +6 seconds without leaking a subsequent turn into an old wake.
        let refreshed = try await settle("ledger-flush-refresh")
        now.addTimeInterval(6)
        try HelperGuardChecks.expect(s.fileReport(.init(summary: "FLUSH-REFRESH-REPORT"), for: refreshed, at: now), "flush-refresh report refused")
        now.addTimeInterval(3)
        await s.flushHelperCompletions()
        let refreshWake = await waitUntil(timeout: 15, pollInterval: 0.02) { wakes().count == beforeWake + 2 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(refreshWake && wakes().last?.contains("FLUSH-REFRESH-REPORT") == true,
            "flush used stale completion report")
        print("helper-completion-check: same-turn report at +6 seconds refreshed at admission PASS")

        // Output arriving after durable admission cannot enter that earlier wake.
        let late = try await settle("ledger-late")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let lateWake = await waitUntil(timeout: 15, pollInterval: 0.02) { wakes().count == beforeWake + 3 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(lateWake, "late-output fixture wake missing")
        now.addTimeInterval(7)
        s.qaDeliver(.contentDelta(threadId: AgentSupervisor.threadId(for: late), turnId: "late-turn", streamKind: .assistant, delta: "LATE-OUTPUT-16s"), to: late)
        try HelperGuardChecks.expect(s.qaFinalAssistantText(for: late)?.contains("LATE-OUTPUT-16s") == true,
            "late assistant output did not reach the production projection")
        try HelperGuardChecks.expect(s.fileReport(.init(summary: "LATE-REPORT-16s"), for: late, at: now), "late report fixture was refused")
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(wakes().count == beforeWake + 3 && !wakes().joined().contains("LATE-REPORT-16s") && !wakes().joined().contains("LATE-OUTPUT-16s"),
            "late report behavior changed; update documented limitation")
        print("helper-completion-check: late report at +16 logical seconds is absent from captured wake (known limitation)")
        let node = Process()
        node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/check-helper-delivery-pi.mjs")
        node.arguments = ["node", script.path]
        try node.run()
        node.waitUntilExit()
        try HelperGuardChecks.expect(node.terminationStatus == 0, "Pi file-reader delivery witness failed")
    }

    static func runDeliveryFailures() async throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-delivery-failures")
        defer { bench.tearDown() }
        let s = bench.supervisor, parent = bench.f.agentId
        let cwd = s.records[parent]!.cwd
        var now = Date()
        s.helperCompletionNow = { now }; s.helperCompletionEnabled = { _ in true }
        let coalescingPeer = try bench.delegate("HOLD-coalescing-peer")
        let peerReady = await waitUntil(timeout: 15, pollInterval: 0.02) { s.isRunning(coalescingPeer) }
        try HelperGuardChecks.expect(peerReady, "idle coalescing peer did not start")
        func settle(_ marker: String) async throws -> AgentID {
            let child = try bench.delegate(marker)
            let idle = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(child) && s.records[child]?.latestTerminalEvent != nil }
            try HelperGuardChecks.expect(idle, "failure-fixture helper did not settle")
            return child
        }
        func get(_ child: AgentID, _ id: String, receipt: String? = nil, ack: Bool = false) -> WorkspaceAPIService.Reply {
            var payload: [String: Any] = ["operationId": s.records[child]!.spawnResultHandle!]
            if let receipt { payload["deliveryReceipt"] = receipt }
            if ack { payload["acknowledgeDelivery"] = true }
            return bench.f.api.dispatch(agentId: parent, requestId: id, op: "operation.get", payload: payload)
        }
        func childResult(_ reply: WorkspaceAPIService.Reply) throws -> [String: AnyHashableJSON] {
            guard case let .result(fields) = reply, let child = fields["childResult"]?.object else {
                throw WorkspaceAgentReportChecks.Failure(description: "missing child result: \(reply)")
            }
            return child
        }
        func wakes() -> [String] {
            let log = (try? String(contentsOf: URL(fileURLWithPath: cwd).appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
            return log.split(separator: "\n").compactMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) }
                .filter { isCompletionMessage($0) }
        }
        // Drop the first host reply, then retry the identical request. It must
        // replay the durable full offer; a new caller waits for its lease.
        let dropped = try await settle("failure-dropped")
        let first = try childResult(get(dropped, "dropped-response"))
        let replayed = try childResult(get(dropped, "dropped-response"))
        try HelperGuardChecks.expect(first == replayed && first["finalText"] != nil, "dropped lookup response was stranded")
        let pending = try childResult(get(dropped, "different-lookup"))
        try HelperGuardChecks.expect(pending["status"]?.string == "delivery_pending" && pending["finalText"] == nil,
            "unacknowledged lookup masqueraded as delivered")
        now.addTimeInterval(31)
        let recovered = try childResult(get(dropped, "restarted-lookup"))
        try HelperGuardChecks.expect(recovered["finalText"] != nil && recovered["deliveryReceipt"] != first["deliveryReceipt"],
            "interrupted collection lease did not recover")
        let receipt = recovered["deliveryReceipt"]!.string!
        _ = get(dropped, "restarted-ack", receipt: receipt, ack: true)
        let duplicate = try childResult(get(dropped, "later-lookup"))
        try HelperGuardChecks.expect(duplicate["status"]?.string == "already_delivered" && duplicate["finalText"] == nil, "ack did not suppress duplicate")
        let explicitReplay = try childResult(get(dropped, "explicit-recovery", receipt: receipt))
        try HelperGuardChecks.expect(explicitReplay["finalText"] != nil, "explicit lost-response recovery failed")
        print("helper-completion-check: dropped-response replay, expired collection lease, acknowledgment PASS")

        // Real host authentication: the helper's own MCP token cannot collect
        // the parent's handle, including the legacy-file fallback.
        let foreignConfig = try bench.configuration(for: dropped)
        let foreign = try await WorkspaceAgentReportChecks.call(foreignConfig, "array_get_operation",
            ["operationId": s.records[dropped]!.spawnResultHandle!])
        try HelperGuardChecks.expect(foreign.isError && (foreign.reply["result"] as? [String: Any])?["childResult"] == nil,
            "foreign authenticated recipient collected another lead's result")
        // A forged courier recipient must not defeat registry ownership in
        // the legacy-file fallback either.
        let originalCourier = SpawnResultFile.read(parentCwd: cwd, handle: s.records[dropped]!.spawnResultHandle!)!
        var forgedCourier = originalCourier; forgedCourier.recipientId = dropped.rawValue
        try HelperGuardChecks.expect(SpawnResultFile.write(forgedCourier, parentCwd: cwd), "forged recipient fixture write failed")
        let forged = try await WorkspaceAgentReportChecks.call(foreignConfig, "array_get_operation",
            ["operationId": s.records[dropped]!.spawnResultHandle!])
        try HelperGuardChecks.expect(forged.isError && (forged.reply["error"] as? [String: Any])?["code"] as? String == "not_found",
            "forged courier recipient bypassed host registry ownership")
        try HelperGuardChecks.expect(SpawnResultFile.write(originalCourier, parentCwd: cwd), "courier restoration failed")
        print("helper-completion-check: authenticated foreign-recipient and forged-courier lookup refused PASS")

        // An unreadable journal is a retryable error, never already_delivered.
        let io = try await settle("failure-storage")
        let ioFile = SpawnResultFile.read(parentCwd: cwd, handle: s.records[io]!.spawnResultHandle!)!
        let url = SpawnResultFile.deliveryURL(parentCwd: cwd, helper: io.rawValue, turn: ioFile.turnIdentity!, recipient: parent.rawValue)!
        let saved = url.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: url, to: saved)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let broken = get(io, "storage-error")
        guard case let .error(error) = broken else { throw WorkspaceAgentReportChecks.Failure(description: "storage failure pretended delivery: \(broken)") }
        try HelperGuardChecks.expect(error.code == .outcomeUnknown, "storage failure lost retryable error")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: saved, to: url)
        let repaired = try childResult(get(io, "storage-error"))
        try HelperGuardChecks.expect(repaired["finalText"] != nil, "repair did not recover the lookup")
        _ = get(io, "storage-ack", receipt: repaired["deliveryReceipt"]!.string!, ack: true)
        print("helper-completion-check: journal I/O failure stays retryable PASS")

        // Fail the ACTUAL throwing queue write by replacing only this fixture's
        // queue directory with a regular file. No delivery commit may survive.
        let queued = try await settle("failure-queue")
        let support = AgentStore(smokeTest: false).layout.applicationSupportDirectory
        let layout = AgentComposerDraftStoreLayout(applicationSupportDirectory: support)
        let queueDir = layout.queuedMessagesDirectory
        try FileManager.default.createDirectory(at: queueDir, withIntermediateDirectories: true)
        let queueSaved = queueDir.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: queueDir, to: queueSaved)
        try Data("block queue admission".utf8).write(to: queueDir)
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let queuedFile = SpawnResultFile.read(parentCwd: cwd, handle: s.records[queued]!.spawnResultHandle!)!
        let staging = try SpawnResultFile.delivery(parentCwd: cwd, helper: queued.rawValue, turn: queuedFile.turnIdentity!, recipient: parent.rawValue)
        try HelperGuardChecks.expect(staging?.phase == .stagingWake && wakes().isEmpty, "failed queue admission committed a wake")
        try FileManager.default.removeItem(at: queueDir)
        try FileManager.default.moveItem(at: queueSaved, to: queueDir)
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let retried = await waitUntil(timeout: 15, pollInterval: 0.02) { wakes().count == 1 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(retried, "queue admission failure did not retry")
        print("helper-completion-check: failed durable queue admission retries once PASS")

        // Interrupt after queue persistence but before delivery commit. A fresh
        // supervisor and fresh queue store must reuse the durable occurrence id.
        let interrupted = try await settle("failure-interrupted")
        s.qaAfterHelperWakeStage = { throw WorkspaceAgentReportChecks.Failure(description: "fixture interrupted before commit") }
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(wakes().count == 1 && s.queuedMessages(for: parent).count == 1, "staging did not retain exactly one durable queue row")
        s.helperCompletionEnabled = { _ in false }
        s.qaForgetHelperCompletionBatches(); s.stopAll()
        let freshQueue = AgentComposerDraftStore(applicationSupportDirectory: support)
        let restored = AgentSupervisor(store: AgentStore(smokeTest: false), submissionRecoveryStore: freshQueue)
        defer { restored.stopAll() }
        restored.helperCompletionNow = { now }; restored.helperCompletionEnabled = { _ in true }
        _ = restored.restore()
        await restored.flushHelperCompletions()
        let resumed = await waitUntil(timeout: 15, pollInterval: 0.02) { wakes().count == 2 && !restored.isRunning(parent) }
        try HelperGuardChecks.expect(resumed, "fresh supervisor did not finish interrupted admission")
        let final = SpawnResultFile.read(parentCwd: cwd, handle: restored.records[interrupted]!.spawnResultHandle!)!
        let committed = try SpawnResultFile.delivery(parentCwd: cwd, helper: interrupted.rawValue, turn: final.turnIdentity!, recipient: parent.rawValue)
        try HelperGuardChecks.expect(committed?.phase == .delivered && wakes().count == 2, "interrupted wake duplicated or lost commit")
        print("helper-completion-check: restart after durable queue stage reuses one occurrence PASS")
    }

    /// Real managed Codex lead -> fixture CLI -> authenticated MCP delegation
    /// and reports -> production terminal ingestion and completion wake delivery.
    static func runDelegateAndMoveOn() async throws {
        let b = try ManagedCodexChecks.bench()
        let restore = ManagedCodexChecks.runEnvironment(b)
        defer {
            if let path = ProcessInfo.processInfo.environment["CONTINUUM_DELEGATE_MOVE_ON_CAPTURE"],
               let data = try? Data(contentsOf: ManagedCodexChecks.log(b)) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            b.tearDown(); restore()
        }
        let cli = b.binDir.appendingPathComponent("codex")
        try FileManager.default.removeItem(at: cli)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "scripts/fixtures/codex-delegate-move-on-cli.py"), to: cli)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "scripts/fixtures/codex-hook-cli.py"),
            to: b.binDir.appendingPathComponent("codex-hook-cli.py"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let s = b.supervisor, lead = b.f.agentId
        try HelperGuardChecks.expect(s.setProviderSettings(agentID: lead, harness: .codex, model: ManagedCodexChecks.model)
            && s.setMode(.managed, for: lead), "could not configure managed Codex lead")
        var now = Date(), starts = 0, steerReady = false
        s.helperCompletionNow = { now }
        let observer = s.addDeliveredEventObserver { id, event in
            if id == lead, case .turnStarted = event { starts += 1 }
        }
        let readiness = s.addTurnCapabilitiesObserver { id in
            if id == lead, s.turnSnapshot(for: lead)?.capabilities.canSteer == true { steerReady = true }
        }
        defer { s.removeDeliveredEventObserver(observer); s.removeTurnCapabilitiesObserver(readiness) }
        try HelperGuardChecks.expect(s.wakesForHelperCompletion(lead), "managed lead default did not enable result wakes")
        try HelperGuardChecks.expect(s.send("CARD4-DELEGATE", to: lead), "lead did not start")
        let delegated = await waitUntil(timeout: 25, pollInterval: 0.02) {
            !ManagedCodexChecks.rows(b, kind: "card4-delegated").isEmpty && !s.isRunning(lead)
        }
        try HelperGuardChecks.expect(delegated, "managed fixture did not delegate and end its turn")
        let calls = ManagedCodexChecks.rows(b, kind: "card4-call")
        try HelperGuardChecks.expect(!calls.contains { $0["tool"] as? String == "wait_agents" },
            "managed lead made a still-running wait_agents poll instead of delegating and moving on")
        try HelperGuardChecks.expect(steerReady && starts == 1, "delegating lead lost steer readiness or added turns")
        let children = s.records.values.filter { $0.parentAgentID == lead }.sorted { $0.humanDisplayName < $1.humanDisplayName }
        try HelperGuardChecks.expect(children.count == 3, "fixture did not create three helpers")
        let ready = await waitUntil(timeout: 15, pollInterval: 0.02) { ManagedCodexChecks.rows(b, kind: "card4-helper-ready").count == 3 }
        try HelperGuardChecks.expect(ready, "helpers did not reach their fixture barriers")
        func release(_ index: Int) throws {
            try Data().write(to: URL(fileURLWithPath: ManagedCodexChecks.log(b).path + ".helper-\(index)"))
        }
        func settled(_ index: Int) async throws {
            let done = await waitUntil(timeout: 15, pollInterval: 0.02) {
                !s.isRunning(children[index].id) && s.records[children[index].id]?.lastReport != nil
            }
            try HelperGuardChecks.expect(done, "helper did not file and settle")
        }
        func woke(_ count: Int) async throws {
            let done = await waitUntil(timeout: 15, pollInterval: 0.02) {
                ManagedCodexChecks.rows(b, kind: "card4-wake").count == count && !s.isRunning(lead)
            }
            try HelperGuardChecks.expect(done, "lead did not wake with helper result")
        }
        try release(0); try await settled(0)
        now.addTimeInterval(7); await s.flushHelperCompletions()
        try HelperGuardChecks.expect(ManagedCodexChecks.rows(b, kind: "card4-wake").isEmpty,
            "idle lead with running helpers did not coalesce for eight seconds")
        now.addTimeInterval(2); await s.flushHelperCompletions(); try await woke(1)
        try HelperGuardChecks.expect(s.send("CARD4-BUSY", to: lead), "independent lead work refused")
        let busy = await waitUntil(timeout: 15, pollInterval: 0.02) { !ManagedCodexChecks.rows(b, kind: "card4-busy").isEmpty }
        try HelperGuardChecks.expect(busy && s.turnSnapshot(for: lead)?.capabilities.canSteer == true, "working lead not steer-ready")
        try release(1); try await settled(1); await s.flushHelperCompletions()
        try HelperGuardChecks.expect(s.queuedMessages(for: lead).count == 1,
            "busy lead result waited eight seconds instead of entering inbox promptly")
        try Data().write(to: URL(fileURLWithPath: ManagedCodexChecks.log(b).path + ".lead-release"))
        try await woke(2)
        try release(2); try await settled(2); await s.flushHelperCompletions(); try await woke(3)
        try HelperGuardChecks.expect(starts == 5, "expected initial delegation, independent work and three result turns")
        let wakes = ManagedCodexChecks.rows(b, kind: "card4-wake")
        for index in 0..<3 {
            try HelperGuardChecks.expect((wakes[index]["text"] as? String)?.contains("CARD4-RESULT-\(index)") == true,
                "helper completion lost its report content")
        }
        try HelperGuardChecks.expect(!ManagedCodexChecks.rows(b, kind: "card4-call").contains { $0["tool"] as? String == "wait_agents" },
            "completion wake polled still-running helpers")
        print("Delegate-and-move-on passed: production managed Codex fixture, three helpers, five lead turns, zero waits, steer-ready")
    }

    static func run() async throws {
        try await runDelegateAndMoveOn()
        try await runDeliveryLedger()
        try await runDeliveryFailures()
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let priorPi = try Data(contentsOf: fixtureRoot.appendingPathComponent("scripts/fixtures/pi-spawn-before-delivery.ts"))
        let installDir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-pi-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: installDir) }
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let installed = installDir.appendingPathComponent(PiExtensionInstaller.extensionFileName)
        try priorPi.write(to: installed)
        let replacement = PiExtensionInstaller.bundledExtensionContent()!
        try HelperGuardChecks.expect(PiExtensionInstaller.install(sourceContent: replacement, destinationDirectory: installDir) == .installed,
            "shipped Pi file reader did not upgrade to authenticated collector")
        let upgraded = try Data(contentsOf: installed)
        try HelperGuardChecks.expect(upgraded == replacement, "Pi upgrade wrote incorrect bytes")
        let userEdited = priorPi + Data("\n// user edit\n".utf8)
        try userEdited.write(to: installed)
        try HelperGuardChecks.expect(PiExtensionInstaller.install(sourceContent: replacement, destinationDirectory: installDir) == .leftUserModifiedCopy,
            "Pi upgrade overwrote a user-modified extension")
        print("helper-completion-check: shipped Pi extension upgrades; user edits preserved PASS")
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper completion check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-completion")
        defer { bench.tearDown() }
        let script = WorkspaceAgentReportChecks.fakePi.replacingOccurrences(
            of: "if \"HOLD\" in json.dumps(text):",
            with: "if \"HOLD\" in json.dumps(text) and not any((\" finished: \" in line and not line.startswith(\"<\")) or line == \"Helper turn updates\" for line in str(text).splitlines()):")
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
            checks: [.init(what: "PASS-OMITTED", result: .pass), .init(what: "swift test", result: .pass), .init(what: "FAIL-RETAINED", result: .fail), .init(what: "INFO-RETAINED", result: .info)],
            findings: Array(repeating: .init(level: .note, text: String(repeating: "detail ", count: 55), location: "Sources/Wake.swift"), count: 6),
            next: "WAKE-NEXT", detailsPath: "WAKE-DETAILS"), for: child)
        finish(child, "first")
        let storedReport = s.records[child]?.lastReport?.report
        let resultReport = SpawnResultFile.read(parentCwd: s.records[parent]!.cwd,
            handle: s.records[child]!.spawnResultHandle!)?.report
        try HelperGuardChecks.expect(storedReport?.checks.contains(where: { $0.what == "PASS-OMITTED" }) == true
            && storedReport?.commandEvidence?.first?.outcome == .notObserved
            && resultReport == storedReport, "wake formatting changed the structured record or result file")
        // Final-helper results are eligible promptly under card 4.
        await s.flushHelperCompletions()
        let cwd = URL(fileURLWithPath: s.records[parent]!.cwd)
        func log() -> String { (try? String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        func wakeCount() -> Int {
            log().split(separator: "\n").compactMap { line -> String? in
                try? JSONDecoder().decode(String.self, from: Data(line.utf8))
            }.filter { isCompletionMessage($0) }.count
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
        for (i, c) in children.enumerated() {
            _ = s.fileReport(.init(summary: "BUSY-REPORT-\(i)",
                checks: [.init(what: "PASS-OMITTED", result: .pass), .init(what: "FAIL-RETAINED", result: .fail)],
                findings: [.init(level: .issue, text: "BUSY-FINDING-\(i)", location: "Sources/Busy.swift")],
                next: "BUSY-NEXT", detailsPath: "BUSY-DETAILS"), for: c)
            finish(c, "group-\(i)", i == 0 ? .failed : .interrupted)
        }
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let updates = s.queuedMessages(for: parent).filter { isCompletionMessage($0.text) }
        try HelperGuardChecks.expect(updates.count == 1 && children.allSatisfy { updates[0].text.contains(s.records[$0]!.humanDisplayName) }, "busy lead did not queue one grouped update")
        var batchProjection = AgentTranscriptProjection(threadId: "batch-attribution")
        batchProjection.appendUserPrompt(updates[0].text)
        let batchMessages = batchProjection.document.entries.flatMap(\.blocks).compactMap { block -> AgentMessagePayload? in
            if case let .agentMessage(payload) = block.payload { return payload }
            return nil
        }
        try HelperGuardChecks.expect(batchMessages.count == 3, "three helper results must project as three separately attributed messages in one prompt")
        for (index, childID) in children.enumerated() {
            try HelperGuardChecks.expect(batchMessages[index].senderAgentID == childID.rawValue
                && batchMessages[index].senderName == s.records[childID]!.humanDisplayName
                && batchMessages[index].text.contains("BUSY-REPORT-\(index)")
                && (0..<3).filter { $0 != index }.allSatisfy { !batchMessages[index].text.contains("BUSY-REPORT-\($0)") },
                "helper result attributed to another batch member")
        }
        // Regressed in 4fa6e039: composer admission inserted U+200B inside
        // the host envelope. Check the actual queued payload, then the live
        // document after the queue drains, rather than just matching its body.
        guard case let .agentMessages(queuedPayloads) = AgentMessageEnvelope.classify(updates[0].text),
              let queuedPayload = queuedPayloads.first else {
            throw WorkspaceAgentReportChecks.Failure(description: "busy helper completion lost structured agent attribution")
        }
        try HelperGuardChecks.expect(queuedPayload.senderAgentID == children[0].rawValue && queuedPayload.text.hasPrefix("\(s.records[children[0]]!.humanDisplayName) finished: failed"),
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
        try HelperGuardChecks.expect(pendingPreviews == Array(repeating: "3 helpers · \(s.records[children[0]]!.humanDisplayName) finished: failed: work failed", count: 2),
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
        try HelperGuardChecks.expect(s.queuedMessages(for: parent).filter { isCompletionMessage($0.text) }.count == 1, "queued update repeated")
        let end = Date().addingTimeInterval(20)
        while Date() < end && (s.isRunning(parent) || !s.queuedMessages(for: parent).isEmpty) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try HelperGuardChecks.expect(wakeCount() == 2, "group did not deliver once after busy turn; queued=\(s.queuedMessages(for: parent).count), running=\(s.isRunning(parent)), log=\(log())")
        let wakeBlocks = s.transcriptDocumentProjection(for: parent)?.entries.flatMap(\.blocks).filter { block in
            if case let .agentMessage(payload) = block.payload { return (payload.text.contains(" finished: ") || payload.text.hasPrefix("Helper turn updates\n")) }
            return false
        } ?? []
        try HelperGuardChecks.expect(wakeBlocks.count == 4,
            "idle and busy completion updates must both project as agent-message cards")
        for (index, block) in wakeBlocks.enumerated() {
            guard case let .agentMessage(payload) = block.payload else { continue }
            try HelperGuardChecks.expect(!payload.text.contains("{\"") && !payload.text.contains("commandEvidence")
                && !payload.text.contains("Helper turn updates") && !payload.text.contains("PASS-OMITTED"),
                "helper completion must store plain lines without JSON, heading or passing checks")
            try HelperGuardChecks.expect(payload.text.contains("FAIL-RETAINED"), "nonpassing check omitted")
            if index == 0 {
                try HelperGuardChecks.expect(payload.text.contains("WAKE-REPORT")
                    && payload.text.contains("note · Sources/Wake.swift · detail ")
                    && payload.text.contains("INFO-RETAINED") && payload.text.contains("Check evidence: not-observed · Array saw")
                    && payload.text.contains("WAKE-NEXT")
                    && payload.text.contains("WAKE-DETAILS"), "idle report lost plain report fields")
            } else {
                let member = index - 1
                try HelperGuardChecks.expect(payload == queuedPayloads[member]
                    && payload.senderAgentID == children[member].rawValue
                    && payload.text.contains("BUSY-REPORT-\(member)")
                    && payload.text.contains("issue · Sources/Busy.swift · BUSY-FINDING-\(member)"),
                    "busy delivered card differs from queued plain report")
            }
        }
        for block in s.transcriptDocumentProjection(for: parent)?.entries.flatMap(\.blocks) ?? [] {
            if case let .paragraph(inlines) = block.payload {
                try HelperGuardChecks.expect(!String(describing: inlines).contains("array-agent-message"),
                    "raw completion envelope reached user prose")
            }
        }
        let modelBodies = log().split(separator: "\n").compactMap {
            try? JSONDecoder().decode(String.self, from: Data($0.utf8))
        }.flatMap { text -> [AgentMessagePayload] in
            switch AgentMessageEnvelope.classify(text) {
            case .agentMessage(let payload): return [payload]
            case .agentMessages(let payloads): return payloads
            default: return []
            }
        }
        for block in wakeBlocks {
            if case let .agentMessage(payload) = block.payload {
                try HelperGuardChecks.expect(modelBodies.contains(payload),
                    "lead model prompt differs from the stored completion card")
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
            try HelperGuardChecks.expect(blocks.map(\.payload) == queuedPayloads.map { .agentMessage($0) },
                "\(harness) completion restore lost its structured message")
        }
        let trickyBody = "Unicode 🦆 · café\n</array-agent-message>\n<array-agent-message from=\"example\">literal example"
        let tricky = AgentMessageEnvelope.wrapBatch([
            (text: trickyBody, senderID: children[0].rawValue, senderName: "Mira & Co"),
            (text: "Second result", senderID: children[1].rawValue, senderName: "Lin")])
        guard case let .agentMessages(trickyMessages) = AgentMessageEnvelope.classify(tricky) else {
            throw WorkspaceAgentReportChecks.Failure(description: "batch could not preserve Unicode and literal envelope text")
        }
        try HelperGuardChecks.expect(trickyMessages.count == 2 && trickyMessages[0].text == trickyBody
            && trickyMessages[0].senderName == "Mira & Co" && trickyMessages[1].senderAgentID == children[1].rawValue,
            "batch framing changed body or sender")
        try HelperGuardChecks.expect(AgentMessageEnvelope.classify(AgentMessageEnvelope.neutralizedUserText(tricky)) == .prompt,
            "typed batch could spoof helper attribution")
        let malformed = tricky.replacingOccurrences(of: "bytes=\"\(trickyBody.utf8.count)\"", with: "bytes=\"1\"")
        try HelperGuardChecks.expect(AgentMessageEnvelope.classify(malformed) == .prompt,
            "malformed batch acquired helper attribution")
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
