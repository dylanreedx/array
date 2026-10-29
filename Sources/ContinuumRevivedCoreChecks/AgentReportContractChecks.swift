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
           && !subReason.contains("array_report") && subReason.contains("Save the full details to a file"),
           "push-back: the reason states the length, asks for ~300 words and a file; array_report only for a delegated agent")
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
    print("Agent report contract checks passed: report and status bounds, the declared label, the courier unchanged without a report, the once-only push-back for helpers, a reason that defers to the brief, two self-only catalogue tools and one Settings toggle off by default")
}
