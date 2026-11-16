import ContinuumRevivedCore
import Foundation

/// `.plans/102` P2a: the pure half of short reports and declared status. The
/// bounds `array_report` / `array_status` enforce, the push-back decision the
/// hook reply carries, the courier staying the same file when no report was
/// filed, the two catalogue entries, and the one Settings row (default off,
/// D1). The app legs `--workspace-agent-report-check` and
/// `--workspace-hook-pushback-check` drive the same code through the real
/// binary and host. RED before P2a: none of these types existed.
func runAgentReportContractChecks() {
    func report(_ payload: [String: Any]) -> AgentReport? {
        if case .success(let value) = AgentReport.validated(payload: payload) { return value }
        return nil
    }
    func refused(_ payload: [String: Any]) -> Bool {
        if case .failure(let error) = AgentReport.validated(payload: payload) {
            return error.code == .invalidRequest && error.message.contains("Nothing was recorded")
        }
        return false
    }
    func words(_ count: Int) -> String { (0..<count).map { "w\($0)" }.joined(separator: " ") }

    // MARK: array_report bounds

    expect(report(["summary": words(AgentReport.summaryMaxWords)]) != nil, "report: a 60-word summary is allowed")
    expect(refused(["summary": words(AgentReport.summaryMaxWords + 1)]), "report: a 61-word summary is refused")
    expect(refused([:]) && refused(["summary": " \n "]) && refused(["summary": 7]), "report: summary is required text")
    let check = ["what": "build", "result": "pass"]
    expect(report(["summary": "ok", "checks": Array(repeating: check, count: AgentReport.maxChecks)]) != nil
           && refused(["summary": "ok", "checks": Array(repeating: check, count: AgentReport.maxChecks + 1)]),
           "report: at most eight checks")
    expect(refused(["summary": "ok", "checks": [["what": "build", "result": "green"]]])
           && refused(["summary": "ok", "checks": [["what": " ", "result": "pass"]]])
           && refused(["summary": "ok", "checks": [["what": String(repeating: "x", count: AgentReport.lineMaxCharacters + 1), "result": "pass"]]]),
           "report: a check needs a one-line what and pass, fail or info")
    let finding = ["level": "note", "text": "x"]
    expect(report(["summary": "ok", "findings": Array(repeating: finding, count: AgentReport.maxFindings)]) != nil
           && refused(["summary": "ok", "findings": Array(repeating: finding, count: AgentReport.maxFindings + 1)]),
           "report: at most six findings")
    expect(refused(["summary": "ok", "findings": [["level": "fatal", "text": "x"]]])
           && refused(["summary": "ok", "findings": [["level": "issue", "text": String(repeating: "x", count: AgentReport.findingTextMaxCharacters + 1)]]])
           && refused(["summary": "ok", "findings": [["level": "issue", "text": "x", "where": String(repeating: "x", count: AgentReport.lineMaxCharacters + 1)]]]),
           "report: a finding needs one of the four levels and bounded text and where")
    expect(refused(["summary": "ok", "next": String(repeating: "x", count: AgentReport.lineMaxCharacters + 1)])
           && refused(["summary": "ok", "detailsPath": "a\u{0}b"])
           && refused(["summary": "ok", "detailsPath": String(repeating: "p", count: AgentReport.detailsPathMaxCharacters + 1)]),
           "report: next and detailsPath are bounded")
    let full = report([
        "summary": "  fixed it  ", "checks": [["what": "swift\n build", "result": "fail"]],
        "findings": [["level": "blocker", "text": "off by one", "where": "  A.swift:3 "]],
        "next": "", "detailsPath": "/tmp/d.md", "unknownField": "ignored",
    ])
    expect(full == AgentReport(summary: "fixed it", checks: [.init(what: "swift build", result: .fail)],
                               findings: [.init(level: .blocker, text: "off by one", location: "A.swift:3")],
                               next: nil, detailsPath: "/tmp/d.md"),
           "report: text is trimmed, one-line fields fold, empty optionals drop: \(String(describing: full))")
    if let full, let data = try? JSONEncoder().encode(full),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(((object["findings"] as? [[String: Any]])?.first?["where"] as? String) == "A.swift:3" && object["next"] == nil,
               "report: a finding's location is `where` on the wire, and an absent next is not encoded: \(object)")
    }

    // MARK: array_status bounds and the declared label

    let at = Date(timeIntervalSince1970: 1_900_000_000)
    if case .success(let status) = AgentDeclaredStatus.validated(payload: ["now": "reading\n the ledger", "needsYou": " "], at: at) {
        expect(status.now == "reading the ledger" && status.needsYou == nil && status.provenance == "declared" && status.declaredAt == at,
               "status: folded, empty optionals drop, labelled declared, timestamped: \(status)")
    } else {
        expect(false, "status: a valid status was refused")
    }
    for payload: [String: Any] in [[:], ["now": ""], ["now": String(repeating: "n", count: AgentDeclaredStatus.lineMaxCharacters + 1)],
                                   ["now": "ok", "next": String(repeating: "n", count: AgentDeclaredStatus.lineMaxCharacters + 1)],
                                   ["now": 3]] {
        if case .success = AgentDeclaredStatus.validated(payload: payload, at: at) { expect(false, "status: \(payload) must be refused") }
    }

    // MARK: The courier is the same file without a report

    let plain = SpawnResultFile(toolCallId: "h1", status: .completed, finalText: "done", endedAt: at)
    let encoder = JSONCodec.makeEncoder()
    if let data = try? encoder.encode(plain), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(object["report"] == nil, "courier: no report filed means no report key: \(object)")
    }
    var carrying = plain
    carrying.report = full
    if let data = try? encoder.encode(carrying) {
        let decoded = try? JSONCodec.makeDecoder().decode(SpawnResultFile.self, from: data)
        expect(decoded?.report == full && OperationChildResult(decoded ?? plain).report == full,
               "courier: a filed report round-trips into operation.get's child result")
    }

    // MARK: A lead's delivery journal is its own

    // Every lead in one project shares `.array/spawn-results/.deliveries/`, and
    // `.array/` is shared across app versions. A record this build cannot decode
    // that belongs to ANOTHER lead must not make this lead's journal unreadable.
    // That failure turned every helper lookup into outcome_unknown and stalled
    // every lead's wakes. It also cost a flush one decode per record in the project.
    let journalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("delivery-journal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: journalRoot) }
    let lead = UUID(), otherLead = UUID(), helper = UUID()
    let turn = UUID().uuidString
    do {
        try SpawnResultFile.saveDelivery(
            SpawnResultFile.Delivery(helper: helper, turn: turn, recipient: lead, now: at), parentCwd: journalRoot.path)
        if let foreign = SpawnResultFile.deliveryURL(parentCwd: journalRoot.path, helper: UUID(),
                                                     turn: UUID().uuidString, recipient: otherLead) {
            try Data("{\"phase\":\"from-a-newer-build\"}".utf8).write(to: foreign)
        }
        let own = try SpawnResultFile.deliveries(parentCwd: journalRoot.path, recipient: lead)
        expect(own.count == 1 && own.first?.helper == helper,
               "journal: a lead reads exactly its own delivery record: \(own)")
    } catch {
        expect(false, "journal: another lead's undecodable record broke this lead's journal: \(error)")
    }

    // A completion should touch its own couriers regardless of how many other
    // helpers the project has accumulated. Count actual read attempts as well
    // as checking that both matching handles, and only those handles, change.
    let courierRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("delivery-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: courierRoot) }
    do {
        var group: [SpawnResultFile.Delivery] = []
        for index in 0..<4 {
            let groupHelper = UUID(), groupTurn = UUID().uuidString
            var delivery = SpawnResultFile.Delivery(helper: groupHelper, turn: groupTurn, recipient: lead, now: at)
            delivery.phase = .delivered
            delivery.via = "wake"
            group.append(delivery)
            for suffix in ["a", "b"] {
                let handle = "matching-\(index)-\(suffix)"
                let file = SpawnResultFile(toolCallId: handle, status: .completed, agentId: groupHelper,
                                           turnIdentity: groupTurn, recipientId: lead)
                expect(SpawnResultFile.write(file, parentCwd: courierRoot.path), "courier: fixture write failed")
            }
        }
        for index in 0..<200 {
            let file = SpawnResultFile(toolCallId: "other-\(index)", status: .completed, agentId: UUID(),
                                       turnIdentity: UUID().uuidString, recipientId: otherLead)
            let data = try JSONCodec.makeEncoder().encode(file)
            try data.write(to: SpawnResultFile.url(parentCwd: courierRoot.path, handle: file.toolCallId))
        }
        let start = ProcessInfo.processInfo.systemUptime
        var reads = 0
        try SpawnResultFile.commitAndMarkDeliveries(group, parentCwd: courierRoot.path, onCourierRead: { _ in reads += 1 })
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        let other = SpawnResultFile.read(parentCwd: courierRoot.path, handle: "other-0")
        let matched = group.enumerated().allSatisfy { index, delivery in
            ["a", "b"].allSatisfy { suffix in
                let file = SpawnResultFile.read(parentCwd: courierRoot.path, handle: "matching-\(index)-\(suffix)")
                return file?.deliveryReceipt == delivery.receipt && file?.deliveredVia == "wake"
            }
        }
        print(String(format: "delivery marking: %d reads for four completions with 200 unrelated, %.2f ms", reads, elapsed))
        expect(matched && other?.deliveryReceipt == nil,
               "delivery marking: all matching couriers must be marked without changing unrelated files")
        expect(reads <= 216, "delivery marking: \(reads) reads for 208 couriers; an admitted batch must scan only once and re-read its eight matches")
        // A courier may be replaced after preparation; a mark must re-read it
        // and preserve newer content or a different recipient's result.
        var race = SpawnResultFile.Delivery(helper: UUID(), turn: UUID().uuidString, recipient: lead, now: at)
        race.phase = .delivered; race.via = "wake"
        let raceFile = SpawnResultFile(toolCallId: "replacement-race", status: .completed, agentId: race.helper,
                                       finalText: "old", turnIdentity: race.turn, recipientId: lead)
        expect(SpawnResultFile.write(raceFile, parentCwd: courierRoot.path), "delivery race: initial courier write failed")
        var newer = raceFile; newer.finalText = "new"
        try SpawnResultFile.commitAndMarkDeliveries([race], parentCwd: courierRoot.path, qaOnPrepared: {
            expect(SpawnResultFile.write(newer, parentCwd: courierRoot.path), "delivery race: replacement write failed")
        })
        let same = SpawnResultFile.read(parentCwd: courierRoot.path, handle: raceFile.toolCallId)
        expect(same?.finalText == "new" && same?.deliveryReceipt == race.receipt,
               "delivery race: keep newer text while marking a matching courier")
        try SpawnResultFile.commitAndMarkDeliveries([race], parentCwd: courierRoot.path, qaOnPrepared: {
            newer.recipientId = otherLead
            expect(SpawnResultFile.write(newer, parentCwd: courierRoot.path), "delivery race: foreign replacement write failed")
        })
        let foreign = SpawnResultFile.read(parentCwd: courierRoot.path, handle: raceFile.toolCallId)
        expect(foreign?.finalText == "new" && foreign?.recipientId == otherLead && foreign?.deliveryReceipt == nil,
               "delivery race: do not overwrite or mark a courier replaced after preparation")

        // An unreadable file can become valid before commit. Preparation must
        // fall back to the old scan rather than permanently dropping it.
        let recoveredURL = SpawnResultFile.url(parentCwd: courierRoot.path, handle: "recovering")
        try Data("{".utf8).write(to: recoveredURL)
        var recovering = raceFile; recovering.toolCallId = "recovering"
        try SpawnResultFile.commitAndMarkDeliveries([race], parentCwd: courierRoot.path, qaOnPrepared: {
            let bytes = try? JSONCodec.makeEncoder().encode(recovering)
            let wrote = bytes.map { (try? $0.write(to: recoveredURL)) != nil } ?? false
            let unmarked = SpawnResultFile.read(parentCwd: courierRoot.path, handle: "recovering")
            expect(wrote && unmarked?.deliveryReceipt == nil, "delivery race: recovering fixture must start unmarked")
        })
        let recovered = SpawnResultFile.read(parentCwd: courierRoot.path, handle: "recovering")
        expect(recovered?.deliveryReceipt == race.receipt && recovered?.deliveredVia == "wake",
               "delivery race: a courier recovered after preparation must still be marked")

        // A failure committing the second delivery must retain the first one's
        // mark and leave all later deliveries uncommitted, as before batching.
        let partial = (0..<3).map { index -> SpawnResultFile.Delivery in
            var value = SpawnResultFile.Delivery(helper: UUID(), turn: "partial-\(index)", recipient: lead, now: at)
            value.phase = .delivered; value.via = "wake"
            return value
        }
        for (index, value) in partial.enumerated() {
            var staged = value; staged.phase = .stagingWake
            try SpawnResultFile.saveDelivery(staged, parentCwd: courierRoot.path)
            let file = SpawnResultFile(toolCallId: "partial-\(index)", status: .completed, agentId: value.helper,
                                       turnIdentity: value.turn, recipientId: lead)
            expect(SpawnResultFile.write(file, parentCwd: courierRoot.path), "delivery partial: courier write failed")
        }
        var attempted = 0, rejected = false
        do {
            try SpawnResultFile.commitAndMarkDeliveries(partial, parentCwd: courierRoot.path, qaBeforeCommit: { _ in
                attempted += 1
                if attempted == 2 { throw CocoaError(.fileWriteNoPermission) }
            })
        } catch { rejected = true }
        let partialFiles = (0..<3).map { SpawnResultFile.read(parentCwd: courierRoot.path, handle: "partial-\($0)") }
        let partialJournals = partial.map { value in
            try? SpawnResultFile.delivery(parentCwd: courierRoot.path, helper: value.helper,
                                          turn: value.turn, recipient: value.recipient)
        }
        expect(rejected && partialFiles[0]?.deliveryReceipt == partial[0].receipt
               && partialFiles[1]?.deliveryReceipt == nil && partialFiles[2]?.deliveryReceipt == nil
               && partialJournals[0]?.phase == .delivered
               && partialJournals[1]?.phase == .stagingWake && partialJournals[2]?.phase == .stagingWake,
               "delivery partial: successful marks and journals precede the next commit; failure leaves later work untouched")
    } catch {
        expect(false, "delivery marking: fixture failed: \(error)")
    }

    // MARK: The push-back decision

    func stop(_ event: String, _ count: Int, active: Bool = false) -> [String: Any] {
        ["hook_event_name": event, "last_assistant_message": words(count), "stop_hook_active": active]
    }
    let limit = AgentShortReportConfig.pushBackWordLimit
    expect(WorkspaceAgentHook.reportPushBack(payload: stop("Stop", limit + 1), callerHasParent: true)?["decision"] as? String == "block",
           "push-back: a delegated helper's Stop over the limit is blocked")
    expect(WorkspaceAgentHook.reportPushBack(payload: stop("Stop", limit), callerHasParent: true) == nil,
           "push-back: exactly at the limit is let through")
    expect(WorkspaceAgentHook.reportPushBack(payload: stop("Stop", 600), callerHasParent: false) == nil,
           "push-back: a top-level agent's own Stop is never blocked")
    expect(WorkspaceAgentHook.reportPushBack(payload: stop("SubagentStop", 600), callerHasParent: false)?["decision"] as? String == "block",
           "push-back: a Claude subagent's long hand-back is blocked in any Array agent")
    expect(WorkspaceAgentHook.reportPushBack(payload: stop("Stop", 600, active: true), callerHasParent: true) == nil
           && WorkspaceAgentHook.reportPushBack(payload: stop("SubagentStop", 600, active: true), callerHasParent: true) == nil,
           "push-back: once only; a continuation (stop_hook_active) is let through")
    expect(WorkspaceAgentHook.reportPushBack(payload: ["hook_event_name": "PreToolUse", "last_assistant_message": words(600)], callerHasParent: true) == nil,
           "push-back: only Stop and SubagentStop")
    expect(WorkspaceAgentHook.reportPushBack(payload: ["hook_event_name": "Stop", WorkspaceAgentHook.trimmedWordCountKey: 600], callerHasParent: true) != nil,
           "push-back: a trimmed body is judged by the count the command sent")
    let stopReason = WorkspaceAgentHook.pushBackReason(words: 612, offersReportTool: true)
    let subReason = WorkspaceAgentHook.pushBackReason(words: 612, offersReportTool: false)
    expect(stopReason.contains("about 612 words") && stopReason.contains("about 300 words") && stopReason.contains("array_report")
           && !subReason.contains("array_report") && subReason.contains("Array is asking you for a details file")
           && subReason.contains("outside the repository"),
           "push-back: the reason states the length, asks for ~300 words and a file; array_report only for a delegated agent")
    // Measured: without this a helper shortened to "the full text is in my
    // previous message", which the parent never receives.
    expect(subReason.contains("Only this last message reaches that agent") && stopReason.contains("Only this last message reaches that agent"),
           "push-back: the reason must say the parent reads only the last message: \(subReason)")
    // P0 finding 5: the brief wins, so the reason names that rather than
    // forbidding anything.
    expect(stopReason.contains("If your task says not to write files, just shorten it")
           && stopReason.contains("If your task asks for the full text, return it unchanged")
           && !stopReason.localizedCaseInsensitiveContains("do not") && !stopReason.localizedCaseInsensitiveContains("must"),
           "push-back: the reason must defer to the helper's brief and forbid nothing: \(stopReason)")

    // MARK: Catalogue and Settings

    for (name, op) in [("array_report", WorkspaceAPIOp.agentReport), ("array_status", .agentStatus)] {
        let tool = WorkspaceMCPToolCatalog.tool(named: name)
        expect(tool?.operation == op && WorkspaceAPIOp.sessionPresetOperations.contains(op)
               && !WorkspaceAPIOp.approvalGatedOperations.contains(op),
               "\(name): a catalogue tool for \(op.rawValue), granted by the session preset (it writes only about the caller)")
        expect((tool?.mcpDescription.count ?? .max) <= 400, "\(name): its description costs context in every session; keep it short")
        expect(tool.map { !$0.inputSchema.keys.contains("agentId") && !String(describing: $0.inputSchema).contains("agentId") } ?? false,
               "\(name): self-only, so the request names no agent")
        expect(ArrayWorkspaceTool(toolName: "mcp__array_workspace__\(name)") != nil, "\(name): its transcript row has a sentence")
    }
    let rows = SettingsSchema.sections().first { $0.id == "agents" }?.groups.flatMap(\.rows) ?? []
    let toggle = rows.first { $0.field.key == AgentShortReportConfig.enabledKey }
    if case .toggle(_, let label, let defaultValue)? = toggle?.field {
        expect(label == "Ask helpers for short reports" && defaultValue == false && AgentShortReportConfig.enabledDefault == false,
               "settings: one Agents toggle, \"Ask helpers for short reports\", off by default (D1)")
    } else {
        expect(false, "settings: the Agents section has no short-reports toggle")
    }
    let suiteName = "array.qa.short-reports.\(UUID().uuidString)"
    if let suite = UserDefaults(suiteName: suiteName) {
        expect(!AgentShortReportConfig.enabled(defaults: suite), "settings: unset reads as off")
        suite.set(true, forKey: AgentShortReportConfig.enabledKey)
        expect(AgentShortReportConfig.enabled(defaults: suite), "settings: on reads as on")
        suite.removePersistentDomain(forName: suiteName)
    }
    print("Agent report contract checks passed: report and status bounds, the declared label, the courier unchanged without a report, the once-only push-back for helpers, a reason that defers to the brief, two self-only catalogue tools, one Settings toggle off by default and a lead reading only its own delivery journal")
}
